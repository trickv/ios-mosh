/*
 * mosh-oracle: mosh 1.4.0's own terminal emulator as a JSON-printing test oracle.
 *
 * Linked against the static libraries of the built mosh 1.4.0 tree (/opt/mosh-src
 * in the dev container). Compiled with -fno-access-control so that it can read the
 * private members of mosh's classes for dumping; that flag only turns off access
 * checking and cannot change a class layout. See README.md and FORMAT.md.
 *
 * Modes:
 *   gen --session FILE --out DIR   server-side simulation (instructions.jsonl, server.jsonl),
 *                                  then the client simulation (expected.jsonl)
 *   apply DIR [--full]             client-side simulation, prints expected.jsonl
 *                                  (--full: every key and every row on every line)
 *   server DIR [--full]            server-side simulation only, prints server.jsonl
 *   screen DIR N|last [--plain] [--server]
 *                                  human-readable state after instruction N (client), or
 *                                  after N session lines (server)
 *   selftest                       dump completeness self-test
 *   respond W H                    co-process for the pty recorder (terminal replies)
 *   predict                        mosh's prediction engine driven by a command stream
 *                                  on stdin (predict.cc, FORMAT.md section 11)
 *
 * This file is a test tool, not part of the app. It is licensed like mosh (GPLv3+),
 * which it links.
 */

#include <errno.h>
#include <locale.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#include "completeterminal.h"
#include "hostinput.pb.h"
#include "parser.h"
#include "oracle.h"

using Terminal::Cell;
using Terminal::Complete;
using Terminal::DrawState;
using Terminal::Framebuffer;
using Terminal::Renditions;
using Terminal::Row;

static const int FORMAT_VERSION = 1;

/* ---------------------------------------------------------------- utilities */

static void die( const char *fmt, ... ) __attribute__(( noreturn, format( printf, 1, 2 ) ));
static void die( const char *fmt, ... )
{
  va_list ap;
  va_start( ap, fmt );
  fprintf( stderr, "mosh-oracle: " );
  vfprintf( stderr, fmt, ap );
  fprintf( stderr, "\n" );
  va_end( ap );
  exit( 2 );
}

static std::string num( long long v )
{
  char buf[ 32 ];
  snprintf( buf, sizeof buf, "%lld", v );
  return buf;
}

static std::string unum( unsigned long long v )
{
  char buf[ 32 ];
  snprintf( buf, sizeof buf, "%llu", v );
  return buf;
}

static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static std::string b64_encode( const std::string &in )
{
  std::string out;
  out.reserve( ( in.size() + 2 ) / 3 * 4 );
  size_t i = 0;
  while ( i + 2 < in.size() ) {
    uint32_t v = ( uint8_t( in[ i ] ) << 16 ) | ( uint8_t( in[ i + 1 ] ) << 8 ) | uint8_t( in[ i + 2 ] );
    out.push_back( B64[ ( v >> 18 ) & 63 ] );
    out.push_back( B64[ ( v >> 12 ) & 63 ] );
    out.push_back( B64[ ( v >> 6 ) & 63 ] );
    out.push_back( B64[ v & 63 ] );
    i += 3;
  }
  if ( i + 1 == in.size() ) {
    uint32_t v = uint8_t( in[ i ] ) << 16;
    out.push_back( B64[ ( v >> 18 ) & 63 ] );
    out.push_back( B64[ ( v >> 12 ) & 63 ] );
    out.append( "==" );
  } else if ( i + 2 == in.size() ) {
    uint32_t v = ( uint8_t( in[ i ] ) << 16 ) | ( uint8_t( in[ i + 1 ] ) << 8 );
    out.push_back( B64[ ( v >> 18 ) & 63 ] );
    out.push_back( B64[ ( v >> 12 ) & 63 ] );
    out.push_back( B64[ ( v >> 6 ) & 63 ] );
    out.push_back( '=' );
  }
  return out;
}

static std::string b64_decode( const std::string &in )
{
  std::string out;
  uint32_t acc = 0;
  int bits = 0;
  size_t pad = 0;
  for ( size_t i = 0; i < in.size(); i++ ) {
    char c = in[ i ];
    if ( c == '=' ) {
      pad++;
      continue;
    }
    if ( pad ) {
      die( "base64: data after padding" );
    }
    const char *p = c ? strchr( B64, c ) : NULL;
    if ( !p ) {
      die( "base64: invalid character 0x%02x", (unsigned char) c );
    }
    acc = ( acc << 6 ) | uint32_t( p - B64 );
    bits += 6;
    if ( bits >= 8 ) {
      bits -= 8;
      out.push_back( char( ( acc >> bits ) & 0xff ) );
    }
  }
  return out;
}

/* Append the UTF-8 encoding of one Unicode scalar value. Independent of the locale. */
static void utf8_append( std::string &out, uint32_t c )
{
  if ( c < 0x80 ) {
    out.push_back( char( c ) );
  } else if ( c < 0x800 ) {
    out.push_back( char( 0xC0 | ( c >> 6 ) ) );
    out.push_back( char( 0x80 | ( c & 0x3F ) ) );
  } else if ( c < 0x10000 ) {
    out.push_back( char( 0xE0 | ( c >> 12 ) ) );
    out.push_back( char( 0x80 | ( ( c >> 6 ) & 0x3F ) ) );
    out.push_back( char( 0x80 | ( c & 0x3F ) ) );
  } else {
    out.push_back( char( 0xF0 | ( c >> 18 ) ) );
    out.push_back( char( 0x80 | ( ( c >> 12 ) & 0x3F ) ) );
    out.push_back( char( 0x80 | ( ( c >> 6 ) & 0x3F ) ) );
    out.push_back( char( 0x80 | ( c & 0x3F ) ) );
  }
}

/* True if s is well-formed UTF-8 (no surrogates, no overlongs, at most U+10FFFF). */
static bool utf8_valid( const std::string &s )
{
  size_t i = 0;
  while ( i < s.size() ) {
    uint8_t c = uint8_t( s[ i ] );
    size_t n;
    uint32_t cp, min;
    if ( c < 0x80 ) { i++; continue; }
    else if ( ( c & 0xE0 ) == 0xC0 ) { n = 1; cp = c & 0x1F; min = 0x80; }
    else if ( ( c & 0xF0 ) == 0xE0 ) { n = 2; cp = c & 0x0F; min = 0x800; }
    else if ( ( c & 0xF8 ) == 0xF0 ) { n = 3; cp = c & 0x07; min = 0x10000; }
    else return false;
    if ( i + n >= s.size() ) return false; /* truncated sequence */
    for ( size_t k = 1; k <= n; k++ ) {
      uint8_t d = uint8_t( s[ i + k ] );
      if ( ( d & 0xC0 ) != 0x80 ) return false;
      cp = ( cp << 6 ) | ( d & 0x3F );
    }
    if ( cp < min || cp > 0x10FFFF || ( cp >= 0xD800 && cp <= 0xDFFF ) ) return false;
    i += n + 1;
  }
  return true;
}

/* JSON string literal from UTF-8 bytes. Escapes ", \, C0 controls and DEL. */
static std::string json_str( const std::string &utf8 )
{
  if ( !utf8_valid( utf8 ) ) {
    die( "internal: string to dump is not valid UTF-8" );
  }
  std::string out( 1, '"' );
  for ( size_t i = 0; i < utf8.size(); i++ ) {
    uint8_t c = uint8_t( utf8[ i ] );
    if ( c == '"' ) {
      out.append( "\\\"" );
    } else if ( c == '\\' ) {
      out.append( "\\\\" );
    } else if ( c < 0x20 || c == 0x7F ) {
      char buf[ 8 ];
      snprintf( buf, sizeof buf, "\\u%04x", c );
      out.append( buf );
    } else {
      out.push_back( char( c ) );
    }
  }
  out.push_back( '"' );
  return out;
}

/* JSON string literal from mosh's vector<wchar_t> (titles, clipboard, OSC string). */
static std::string json_wstr( const std::vector<wchar_t> &w )
{
  std::string utf8;
  for ( size_t i = 0; i < w.size(); i++ ) {
    uint32_t c = uint32_t( w[ i ] );
    if ( c > 0x10FFFF || ( c >= 0xD800 && c <= 0xDFFF ) ) {
      die( "internal: wchar_t outside Unicode scalar range in a title string" );
    }
    utf8_append( utf8, c );
  }
  return json_str( utf8 );
}

static std::string json_bool( bool b ) { return b ? "true" : "false"; }

static std::string json_ints( const std::vector<int> &v )
{
  std::string out( "[" );
  for ( size_t i = 0; i < v.size(); i++ ) {
    if ( i ) out.push_back( ',' );
    out.append( num( v[ i ] ) );
  }
  out.push_back( ']' );
  return out;
}

/* ------------------------------------------------------------- JSON reader */

struct JV {
  enum Type { Null, Bool, Num, Str, Arr, Obj } type;
  bool b;
  bool is_int;
  bool negative;
  unsigned long long u; /* magnitude when is_int */
  double d;
  std::string s;
  std::vector<JV> a;
  std::vector< std::pair<std::string, JV> > o;

  JV() : type( Null ), b( false ), is_int( false ), negative( false ), u( 0 ), d( 0 ), s(), a(), o() {}

  const JV *get( const char *key ) const
  {
    if ( type != Obj ) return NULL;
    for ( size_t i = 0; i < o.size(); i++ ) {
      if ( o[ i ].first == key ) return &o[ i ].second;
    }
    return NULL;
  }

  long long as_ll( const char *what ) const
  {
    if ( type != Num || !is_int ) die( "%s: expected an integer", what );
    return negative ? -(long long) u : (long long) u;
  }

  unsigned long long as_u64( const char *what ) const
  {
    if ( type != Num || !is_int || negative ) die( "%s: expected a non-negative integer", what );
    return u;
  }
};

class JSONReader {
  const std::string &src;
  size_t pos;
  const char *what;

  void fail( const char *msg ) { die( "%s: JSON error at byte %zu: %s", what, pos, msg ); }

  void ws( void )
  {
    while ( pos < src.size() && ( src[ pos ] == ' ' || src[ pos ] == '\t' || src[ pos ] == '\n' || src[ pos ] == '\r' ) ) pos++;
  }

  unsigned hex4( void )
  {
    if ( pos + 4 > src.size() ) fail( "short \\u escape" );
    unsigned v = 0;
    for ( int i = 0; i < 4; i++ ) {
      char c = src[ pos++ ];
      v <<= 4;
      if ( c >= '0' && c <= '9' ) v |= c - '0';
      else if ( c >= 'a' && c <= 'f' ) v |= c - 'a' + 10;
      else if ( c >= 'A' && c <= 'F' ) v |= c - 'A' + 10;
      else fail( "bad \\u escape" );
    }
    return v;
  }

  std::string string( void )
  {
    std::string out;
    pos++; /* opening quote */
    while ( true ) {
      if ( pos >= src.size() ) fail( "unterminated string" );
      char c = src[ pos++ ];
      if ( c == '"' ) break;
      if ( c != '\\' ) {
        out.push_back( c );
        continue;
      }
      if ( pos >= src.size() ) fail( "unterminated escape" );
      char e = src[ pos++ ];
      switch ( e ) {
      case '"': out.push_back( '"' ); break;
      case '\\': out.push_back( '\\' ); break;
      case '/': out.push_back( '/' ); break;
      case 'b': out.push_back( '\b' ); break;
      case 'f': out.push_back( '\f' ); break;
      case 'n': out.push_back( '\n' ); break;
      case 'r': out.push_back( '\r' ); break;
      case 't': out.push_back( '\t' ); break;
      case 'u': {
        uint32_t cp = hex4();
        if ( cp >= 0xD800 && cp <= 0xDBFF ) {
          if ( pos + 2 > src.size() || src[ pos ] != '\\' || src[ pos + 1 ] != 'u' ) fail( "lone surrogate" );
          pos += 2;
          uint32_t lo = hex4();
          if ( lo < 0xDC00 || lo > 0xDFFF ) fail( "bad surrogate pair" );
          cp = 0x10000 + ( ( cp - 0xD800 ) << 10 ) + ( lo - 0xDC00 );
        } else if ( cp >= 0xDC00 && cp <= 0xDFFF ) {
          fail( "lone surrogate" );
        }
        utf8_append( out, cp );
        break;
      }
      default: fail( "bad escape" );
      }
    }
    return out;
  }

  JV value( void )
  {
    ws();
    if ( pos >= src.size() ) fail( "unexpected end" );
    JV v;
    char c = src[ pos ];
    if ( c == '{' ) {
      v.type = JV::Obj;
      pos++;
      ws();
      if ( pos < src.size() && src[ pos ] == '}' ) { pos++; return v; }
      while ( true ) {
        ws();
        if ( pos >= src.size() || src[ pos ] != '"' ) fail( "expected a key" );
        std::string key = string();
        ws();
        if ( pos >= src.size() || src[ pos ] != ':' ) fail( "expected ':'" );
        pos++;
        v.o.push_back( std::make_pair( key, value() ) );
        ws();
        if ( pos < src.size() && src[ pos ] == ',' ) { pos++; continue; }
        if ( pos < src.size() && src[ pos ] == '}' ) { pos++; break; }
        fail( "expected ',' or '}'" );
      }
    } else if ( c == '[' ) {
      v.type = JV::Arr;
      pos++;
      ws();
      if ( pos < src.size() && src[ pos ] == ']' ) { pos++; return v; }
      while ( true ) {
        v.a.push_back( value() );
        ws();
        if ( pos < src.size() && src[ pos ] == ',' ) { pos++; continue; }
        if ( pos < src.size() && src[ pos ] == ']' ) { pos++; break; }
        fail( "expected ',' or ']'" );
      }
    } else if ( c == '"' ) {
      v.type = JV::Str;
      v.s = string();
    } else if ( src.compare( pos, 4, "true" ) == 0 ) {
      v.type = JV::Bool; v.b = true; pos += 4;
    } else if ( src.compare( pos, 5, "false" ) == 0 ) {
      v.type = JV::Bool; v.b = false; pos += 5;
    } else if ( src.compare( pos, 4, "null" ) == 0 ) {
      pos += 4;
    } else if ( c == '-' || ( c >= '0' && c <= '9' ) ) {
      size_t start = pos;
      bool integral = true;
      if ( c == '-' ) pos++;
      while ( pos < src.size() ) {
        char d = src[ pos ];
        if ( d >= '0' && d <= '9' ) { pos++; }
        else if ( d == '.' || d == 'e' || d == 'E' || d == '+' || d == '-' ) { integral = false; pos++; }
        else break;
      }
      std::string text = src.substr( start, pos - start );
      v.type = JV::Num;
      v.d = strtod( text.c_str(), NULL );
      if ( integral ) {
        v.is_int = true;
        v.negative = text[ 0 ] == '-';
        errno = 0;
        v.u = strtoull( text.c_str() + ( v.negative ? 1 : 0 ), NULL, 10 );
        if ( errno ) fail( "integer out of range" );
      }
    } else {
      fail( "unexpected character" );
    }
    return v;
  }

public:
  JSONReader( const std::string &s_src, const char *s_what ) : src( s_src ), pos( 0 ), what( s_what ) {}

  JV parse( void )
  {
    JV v = value();
    ws();
    if ( pos != src.size() ) fail( "trailing data" );
    return v;
  }
};

static std::vector<std::string> read_lines( const std::string &path )
{
  std::ifstream in( path.c_str(), std::ios::binary );
  if ( !in ) die( "cannot open %s", path.c_str() );
  std::vector<std::string> lines;
  std::string line;
  while ( std::getline( in, line ) ) {
    if ( !line.empty() && line[ line.size() - 1 ] == '\r' ) line.erase( line.size() - 1 );
    bool blank = true;
    for ( size_t i = 0; i < line.size(); i++ ) {
      if ( line[ i ] != ' ' && line[ i ] != '\t' ) { blank = false; break; }
    }
    if ( !blank ) lines.push_back( line );
  }
  return lines;
}

/* ----------------------------------------------------------- the full dump */

static const char *parser_state_name( const Parser::State *s )
{
  const Parser::StateFamily &f = Parser::family;
  if ( s == &f.s_Ground ) return "Ground";
  if ( s == &f.s_Escape ) return "Escape";
  if ( s == &f.s_Escape_Intermediate ) return "Escape_Intermediate";
  if ( s == &f.s_CSI_Entry ) return "CSI_Entry";
  if ( s == &f.s_CSI_Param ) return "CSI_Param";
  if ( s == &f.s_CSI_Intermediate ) return "CSI_Intermediate";
  if ( s == &f.s_CSI_Ignore ) return "CSI_Ignore";
  if ( s == &f.s_DCS_Entry ) return "DCS_Entry";
  if ( s == &f.s_DCS_Param ) return "DCS_Param";
  if ( s == &f.s_DCS_Intermediate ) return "DCS_Intermediate";
  if ( s == &f.s_DCS_Passthrough ) return "DCS_Passthrough";
  if ( s == &f.s_DCS_Ignore ) return "DCS_Ignore";
  if ( s == &f.s_OSC_String ) return "OSC_String";
  if ( s == &f.s_SOS_PM_APC_String ) return "SOS_PM_APC_String";
  die( "internal: unknown parser state" );
}

/* {"fg":..,"bg":..,"at":..} members with a leading comma each; zero values are left out. */
static std::string rend_members( const Renditions &r )
{
  std::string out;
  unsigned fg = r.foreground_color, bg = r.background_color, at = r.attributes;
  if ( fg ) out.append( ",\"fg\":" + unum( fg ) );
  if ( bg ) out.append( ",\"bg\":" + unum( bg ) );
  if ( at ) out.append( ",\"at\":" + unum( at ) );
  return out;
}

static std::string rend_object( const Renditions &r )
{
  std::string m = rend_members( r );
  if ( m.empty() ) return "{}";
  return "{" + m.substr( 1 ) + "}";
}

/* Content class of a cell: 'e' empty, 't' one printable ASCII byte, 'c' anything else. */
static char cell_class( const Cell &c )
{
  if ( c.contents.empty() ) return 'e';
  if ( c.contents.size() == 1 && uint8_t( c.contents[ 0 ] ) >= 0x20 && uint8_t( c.contents[ 0 ] ) <= 0x7E ) return 't';
  return 'c';
}

static bool same_cell_attrs( const Cell &a, const Cell &b )
{
  return a.renditions == b.renditions && a.wide == b.wide && a.fallback == b.fallback && a.wrap == b.wrap;
}

/* Canonical JSON of one row: an array of runs. Two rows have the same cells if and
   only if their canonical JSON is the same string. */
static std::string encode_row( const Row &row )
{
  std::string out( "[" );
  const size_t n = row.cells.size();
  size_t i = 0;
  while ( i < n ) {
    const Cell &first = row.cells[ i ];
    const char cls = cell_class( first );
    size_t j = i + 1;
    while ( j < n && cell_class( row.cells[ j ] ) == cls && same_cell_attrs( first, row.cells[ j ] ) ) j++;

    if ( i ) out.push_back( ',' );
    out.push_back( '{' );
    if ( cls == 'e' ) {
      out.append( "\"e\":" + num( (long long) ( j - i ) ) );
    } else if ( cls == 't' ) {
      std::string text;
      for ( size_t k = i; k < j; k++ ) text.push_back( row.cells[ k ].contents[ 0 ] );
      out.append( "\"t\":" + json_str( text ) );
    } else {
      out.append( "\"c\":[" );
      for ( size_t k = i; k < j; k++ ) {
        if ( k > i ) out.push_back( ',' );
        out.append( json_str( row.cells[ k ].contents ) );
      }
      out.push_back( ']' );
    }
    out.append( rend_members( first.renditions ) );
    if ( first.wide ) out.append( ",\"wide\":true" );
    if ( first.fallback ) out.append( ",\"fallback\":true" );
    if ( first.wrap ) out.append( ",\"wrap\":true" );
    out.push_back( '}' );
    i = j;
  }
  out.push_back( ']' );
  return out;
}

typedef std::vector< std::pair<std::string, std::string> > Fields;

struct Dump {
  int width, height;
  Fields fields;                 /* every key except "num" and "rows", fixed order, value as JSON text */
  std::vector<std::string> rows; /* canonical JSON per row */

  Dump() : width( 0 ), height( 0 ), fields(), rows() {}

  const std::string &field( const std::string &key ) const
  {
    for ( size_t i = 0; i < fields.size(); i++ ) {
      if ( fields[ i ].first == key ) return fields[ i ].second;
    }
    die( "internal: no dump field %s", key.c_str() );
  }
};

static Dump make_dump( const Complete &c )
{
  const Framebuffer &fb = c.terminal.fb;
  const DrawState &ds = fb.ds;
  const Terminal::Dispatcher &dp = c.terminal.dispatch;
  Dump d;
  Fields &f = d.fields;

  d.width = ds.width;
  d.height = ds.height;
  if ( (int) fb.rows.size() != ds.height ) die( "internal: row count differs from height" );
  for ( size_t y = 0; y < fb.rows.size(); y++ ) {
    if ( (int) fb.rows[ y ]->cells.size() != ds.width ) die( "internal: row width differs from width" );
    d.rows.push_back( encode_row( *fb.rows[ y ] ) );
  }

  f.push_back( std::make_pair( "width", num( ds.width ) ) );
  f.push_back( std::make_pair( "height", num( ds.height ) ) );
  f.push_back( std::make_pair( "cursor", "[" + num( ds.cursor_row ) + "," + num( ds.cursor_col ) + "]" ) );
  f.push_back( std::make_pair( "combining", "[" + num( ds.combining_char_row ) + "," + num( ds.combining_char_col ) + "]" ) );
  f.push_back( std::make_pair( "default_tabs", json_bool( ds.default_tabs ) ) );
  {
    if ( (int) ds.tabs.size() != ds.width ) die( "internal: tabs size differs from width" );
    std::vector<int> stops;
    for ( size_t i = 0; i < ds.tabs.size(); i++ ) {
      if ( ds.tabs[ i ] ) stops.push_back( int( i ) );
    }
    f.push_back( std::make_pair( "tabs", json_ints( stops ) ) );
  }
  f.push_back( std::make_pair( "scroll_region", "[" + num( ds.scrolling_region_top_row ) + "," + num( ds.scrolling_region_bottom_row ) + "]" ) );
  f.push_back( std::make_pair( "pen", rend_object( ds.renditions ) ) );
  f.push_back( std::make_pair( "saved", "{\"cursor\":[" + num( ds.save.cursor_row ) + "," + num( ds.save.cursor_col ) + "],\"pen\":"
                               + rend_object( ds.save.renditions ) + ",\"auto_wrap_mode\":" + json_bool( ds.save.auto_wrap_mode )
                               + ",\"origin_mode\":" + json_bool( ds.save.origin_mode ) + "}" ) );
  f.push_back( std::make_pair( "next_print_will_wrap", json_bool( ds.next_print_will_wrap ) ) );
  f.push_back( std::make_pair( "origin_mode", json_bool( ds.origin_mode ) ) );
  f.push_back( std::make_pair( "auto_wrap_mode", json_bool( ds.auto_wrap_mode ) ) );
  f.push_back( std::make_pair( "insert_mode", json_bool( ds.insert_mode ) ) );
  f.push_back( std::make_pair( "cursor_visible", json_bool( ds.cursor_visible ) ) );
  f.push_back( std::make_pair( "reverse_video", json_bool( ds.reverse_video ) ) );
  f.push_back( std::make_pair( "bracketed_paste", json_bool( ds.bracketed_paste ) ) );
  f.push_back( std::make_pair( "mouse_reporting_mode", num( int( ds.mouse_reporting_mode ) ) ) );
  f.push_back( std::make_pair( "mouse_focus_event", json_bool( ds.mouse_focus_event ) ) );
  f.push_back( std::make_pair( "mouse_alternate_scroll", json_bool( ds.mouse_alternate_scroll ) ) );
  f.push_back( std::make_pair( "mouse_encoding_mode", num( int( ds.mouse_encoding_mode ) ) ) );
  f.push_back( std::make_pair( "application_mode_cursor_keys", json_bool( ds.application_mode_cursor_keys ) ) );

  f.push_back( std::make_pair( "icon_name", json_wstr( fb.icon_name ) ) );
  f.push_back( std::make_pair( "window_title", json_wstr( fb.window_title ) ) );
  f.push_back( std::make_pair( "title_initialized", json_bool( fb.title_initialized ) ) );
  f.push_back( std::make_pair( "clipboard", json_wstr( fb.clipboard ) ) );
  f.push_back( std::make_pair( "bell_count", unum( fb.bell_count ) ) );

  f.push_back( std::make_pair( "echo_ack", unum( c.echo_ack ) ) );

  f.push_back( std::make_pair( "parser_state", json_str( parser_state_name( c.parser.parser.state ) ) ) );
  {
    std::vector<int> bytes;
    for ( size_t i = 0; i < c.parser.buf_len; i++ ) bytes.push_back( uint8_t( c.parser.buf[ i ] ) );
    f.push_back( std::make_pair( "utf8_buf", json_ints( bytes ) ) );
  }
  f.push_back( std::make_pair( "params", json_str( dp.params ) ) );
  {
    std::vector<int> bytes;
    for ( size_t i = 0; i < dp.dispatch_chars.size(); i++ ) bytes.push_back( uint8_t( dp.dispatch_chars[ i ] ) );
    f.push_back( std::make_pair( "dispatch_chars", json_ints( bytes ) ) );
  }
  f.push_back( std::make_pair( "parsed", json_bool( dp.parsed ) ) );
  f.push_back( std::make_pair( "parsed_params", json_ints( dp.parsed_params ) ) );
  f.push_back( std::make_pair( "osc_string", json_wstr( dp.OSC_string ) ) );

  /* Invariants of a state at rest. If one of these fails the dump would be blind to it. */
  if ( !dp.terminal_to_host.empty() ) die( "internal: terminal_to_host is not empty in a state at rest" );
  if ( !c.actions.empty() ) die( "internal: actions is not empty in a state at rest" );

  return d;
}

/* One line of expected.jsonl: the keys whose value differs from prev, and the rows
   that differ from prev's row with the same index. */
static std::string delta_line( uint64_t new_num, const Dump &prev, const Dump &cur )
{
  std::string out = "{\"num\":" + unum( new_num );
  if ( prev.fields.size() != cur.fields.size() ) die( "internal: field lists differ" );
  for ( size_t i = 0; i < cur.fields.size(); i++ ) {
    if ( cur.fields[ i ].second != prev.fields[ i ].second ) {
      out.append( ",\"" + cur.fields[ i ].first + "\":" + cur.fields[ i ].second );
    }
  }

  const bool resized = prev.width != cur.width || prev.height != cur.height;
  std::string rows;
  for ( size_t y = 0; y < cur.rows.size(); y++ ) {
    std::string entry;
    if ( resized ) {
      entry = cur.rows[ y ];
    } else if ( cur.rows[ y ] == prev.rows[ y ] ) {
      continue;
    } else {
      /* nearest identical row of the previous state, the smaller index on a tie */
      long best = -1;
      for ( size_t dist = 1; dist < prev.rows.size() && best < 0; dist++ ) {
        if ( y >= dist && prev.rows[ y - dist ] == cur.rows[ y ] ) best = long( y - dist );
        else if ( y + dist < prev.rows.size() && prev.rows[ y + dist ] == cur.rows[ y ] ) best = long( y + dist );
      }
      entry = best >= 0 ? num( best ) : cur.rows[ y ];
    }
    if ( !rows.empty() ) rows.push_back( ',' );
    rows.append( "\"" + num( (long long) y ) + "\":" + entry );
  }
  if ( !rows.empty() ) out.append( ",\"rows\":{" + rows + "}" );
  out.push_back( '}' );
  return out;
}

/* The same state without the delta rule: every key, and "rows" as an array of all
   rows. Not a corpus format; it exists so that a loader of the delta format can be
   checked against it (Tools/mosh-oracle/check_format.py). */
static std::string full_line( uint64_t new_num, const Dump &cur )
{
  std::string out = "{\"num\":" + unum( new_num );
  for ( size_t i = 0; i < cur.fields.size(); i++ ) {
    out.append( ",\"" + cur.fields[ i ].first + "\":" + cur.fields[ i ].second );
  }
  out.append( ",\"rows\":[" );
  for ( size_t y = 0; y < cur.rows.size(); y++ ) {
    if ( y ) out.push_back( ',' );
    out.append( cur.rows[ y ] );
  }
  out.append( "]}" );
  return out;
}

/* ------------------------------------------------------------ instructions */

struct Instr {
  uint64_t old_num, new_num;
  std::string diff; /* serialized HostBuffers::HostMessage, may be empty */
};

/* The "ops" array for a diff: the HostMessage decoded in order, choosing among the
   extensions of one Instruction in the same order as Complete::apply_string. */
static std::string ops_json( const std::string &diff )
{
  HostBuffers::HostMessage msg;
  if ( !msg.ParseFromString( diff ) ) die( "diff is not a HostMessage" );
  std::string out( "[" );
  for ( int i = 0; i < msg.instruction_size(); i++ ) {
    const HostBuffers::Instruction &in = msg.instruction( i );
    std::string op;
    if ( in.HasExtension( HostBuffers::hostbytes ) ) {
      op = "{\"hostbytes_b64\":\"" + b64_encode( in.GetExtension( HostBuffers::hostbytes ).hoststring() ) + "\"}";
    } else if ( in.HasExtension( HostBuffers::resize ) ) {
      op = "{\"resize\":[" + num( in.GetExtension( HostBuffers::resize ).width() ) + ","
           + num( in.GetExtension( HostBuffers::resize ).height() ) + "]}";
    } else if ( in.HasExtension( HostBuffers::echoack ) ) {
      op = "{\"echo_ack\":" + unum( in.GetExtension( HostBuffers::echoack ).echo_ack_num() ) + "}";
    } else {
      continue; /* apply_string ignores it too */
    }
    if ( out.size() > 1 ) out.push_back( ',' );
    out.append( op );
  }
  out.push_back( ']' );
  return out;
}

/* Re-serialise a parsed "ops" value in the canonical form of ops_json, for comparison. */
static std::string ops_canonical( const JV &ops, const char *what )
{
  if ( ops.type != JV::Arr ) die( "%s: \"ops\" is not an array", what );
  std::string out( "[" );
  for ( size_t i = 0; i < ops.a.size(); i++ ) {
    const JV &op = ops.a[ i ];
    if ( i ) out.push_back( ',' );
    if ( const JV *hb = op.get( "hostbytes_b64" ) ) {
      if ( hb->type != JV::Str ) die( "%s: hostbytes_b64 is not a string", what );
      out.append( "{\"hostbytes_b64\":\"" + b64_encode( b64_decode( hb->s ) ) + "\"}" );
    } else if ( const JV *rs = op.get( "resize" ) ) {
      if ( rs->type != JV::Arr || rs->a.size() != 2 ) die( "%s: resize is not [w,h]", what );
      out.append( "{\"resize\":[" + num( rs->a[ 0 ].as_ll( what ) ) + "," + num( rs->a[ 1 ].as_ll( what ) ) + "]}" );
    } else if ( const JV *ea = op.get( "echo_ack" ) ) {
      out.append( "{\"echo_ack\":" + unum( ea->as_u64( what ) ) + "}" );
    } else {
      die( "%s: unknown op", what );
    }
  }
  out.push_back( ']' );
  return out;
}

static std::string instr_json( const Instr &in )
{
  return "{\"old_num\":" + unum( in.old_num ) + ",\"new_num\":" + unum( in.new_num ) + ",\"diff_b64\":\""
         + b64_encode( in.diff ) + "\",\"ops\":" + ops_json( in.diff ) + "}";
}

struct Meta {
  int width, height;
};

static Meta read_meta( const std::string &dir )
{
  std::vector<std::string> lines = read_lines( dir + "/meta.json" );
  std::string all;
  for ( size_t i = 0; i < lines.size(); i++ ) all.append( lines[ i ] + "\n" );
  JV v = JSONReader( all, "meta.json" ).parse();
  const JV *fmt = v.get( "format" ), *w = v.get( "width" ), *h = v.get( "height" );
  if ( !fmt || !w || !h ) die( "meta.json: need format, width and height" );
  if ( fmt->as_ll( "meta.json format" ) != FORMAT_VERSION ) die( "meta.json: unsupported format version" );
  Meta m;
  m.width = int( w->as_ll( "meta.json width" ) );
  m.height = int( h->as_ll( "meta.json height" ) );
  if ( m.width < 1 || m.height < 1 ) die( "meta.json: bad size" );
  return m;
}

static std::vector<Instr> read_instructions( const std::string &dir, bool verify_ops )
{
  std::vector<std::string> lines = read_lines( dir + "/instructions.jsonl" );
  std::vector<Instr> out;
  for ( size_t i = 0; i < lines.size(); i++ ) {
    std::string what = "instructions.jsonl line " + num( (long long) i + 1 );
    JV v = JSONReader( lines[ i ], what.c_str() ).parse();
    const JV *o = v.get( "old_num" ), *n = v.get( "new_num" ), *d = v.get( "diff_b64" ), *ops = v.get( "ops" );
    if ( !o || !n || !d || d->type != JV::Str ) die( "%s: need old_num, new_num and diff_b64", what.c_str() );
    Instr in;
    in.old_num = o->as_u64( what.c_str() );
    in.new_num = n->as_u64( what.c_str() );
    in.diff = b64_decode( d->s );
    if ( verify_ops ) {
      if ( !ops ) die( "%s: no \"ops\"", what.c_str() );
      if ( ops_canonical( *ops, what.c_str() ) != ops_json( in.diff ) ) {
        die( "%s: \"ops\" does not match the decoded diff_b64", what.c_str() );
      }
    }
    out.push_back( in );
  }
  return out;
}

/* ------------------------------------------------------- client simulation */

/* What a mosh client does on receive (Network::Transport::recv): keep every state by
   number; copy the state numbered old_num, apply the diff, store it as new_num. */
class Client {
  std::map<uint64_t, Complete> states;

public:
  Client( int width, int height ) : states()
  {
    states.insert( std::make_pair( uint64_t( 0 ), Complete( width, height ) ) );
  }

  const Complete &state( uint64_t n ) const
  {
    std::map<uint64_t, Complete>::const_iterator it = states.find( n );
    if ( it == states.end() ) die( "no state %llu", (unsigned long long) n );
    return it->second;
  }

  const Complete &receive( const Instr &in )
  {
    if ( states.find( in.new_num ) != states.end() ) {
      die( "new_num %llu appears twice", (unsigned long long) in.new_num );
    }
    std::map<uint64_t, Complete>::const_iterator ref = states.find( in.old_num );
    if ( ref == states.end() ) {
      die( "instruction %llu => %llu: the reference state was never received",
           (unsigned long long) in.old_num, (unsigned long long) in.new_num );
    }
    Complete st( ref->second );
    if ( !in.diff.empty() ) { /* recv() does not call apply_string for an empty diff */
      st.apply_string( in.diff );
    }
    return states.insert( std::make_pair( in.new_num, st ) ).first->second;
  }
};

static void apply_dir( const std::string &dir, std::ostream &out, bool verify_ops, bool full = false )
{
  Meta meta = read_meta( dir );
  std::vector<Instr> instrs = read_instructions( dir, verify_ops );
  Client client( meta.width, meta.height );
  Dump prev = make_dump( client.state( 0 ) );
  for ( size_t i = 0; i < instrs.size(); i++ ) {
    Dump cur = make_dump( client.receive( instrs[ i ] ) );
    out << ( full ? full_line( instrs[ i ].new_num, cur ) : delta_line( instrs[ i ].new_num, prev, cur ) ) << "\n";
    prev = cur;
  }
  out.flush();
  if ( !out ) die( "write error" );
}

/* ------------------------------------------------------- server simulation */

/* How many states back the base of instruction k is. Usually 1. Three of every ten
   instructions use an older held state: one single fallback and one pair that shares
   a base, as a server does while acks are late (it falls back to the last
   acknowledged state, and keeps diffing from it until an ack arrives). */
static uint64_t base_age( uint64_t k )
{
  const uint64_t c = k / 10, p = k % 10;
  uint64_t age = 1;
  if ( p == 3 ) age = 2 + c % 7;                /* 2..8 */
  else if ( p == 7 ) age = 2 + ( c + 3 ) % 6;   /* 2..7 */
  else if ( p == 8 ) age = 3 + ( c + 3 ) % 6;   /* 3..8, the same base as instruction k-1 */
  return age > k ? k : age;
}

static void write_file( const std::string &path, const std::string &content )
{
  std::ofstream out( path.c_str(), std::ios::binary | std::ios::trunc );
  if ( !out ) die( "cannot write %s", path.c_str() );
  out << content;
  out.flush();
  if ( !out ) die( "write error on %s", path.c_str() );
}

/* Apply one session line to a server-side terminal, as mosh-server would. Returns the
   terminal's reply to the host (answers to DA and DSR), which a server writes to the
   pty. */
static std::string session_step( Complete &server, const std::string &line, const char *what, uint64_t &fake_clock )
{
  JV v = JSONReader( line, what ).parse();
  std::string reply;
  if ( const JV *b = v.get( "bytes_b64" ) ) {
    if ( b->type != JV::Str ) die( "%s: bytes_b64 is not a string", what );
    reply = server.act( b64_decode( b->s ) );
  } else if ( const JV *r = v.get( "resize" ) ) {
    if ( r->type != JV::Arr || r->a.size() != 2 ) die( "%s: resize is not [w,h]", what );
    const long long rw = r->a[ 0 ].as_ll( what ), rh = r->a[ 1 ].as_ll( what );
    if ( rw < 1 || rh < 1 ) die( "%s: bad size", what );
    server.act( Parser::Resize( size_t( rw ), size_t( rh ) ) );
  } else if ( const JV *e = v.get( "echo_ack" ) ) {
    /* As the server does: note the input frame, and acknowledge it 50 ms later. */
    const uint64_t n = e->as_u64( what );
    if ( n < server.get_echo_ack() ) die( "%s: echo_ack must not decrease", what );
    server.register_input_frame( n, fake_clock );
    fake_clock += 1000;
    server.set_echo_ack( fake_clock );
    fake_clock += 1000;
    if ( server.get_echo_ack() != n ) die( "internal: echo ack not taken" );
  } else {
    die( "%s: need bytes_b64, resize or echo_ack", what );
  }
  return reply;
}

static Complete session_start( const std::vector<std::string> &lines, const char *name )
{
  if ( lines.empty() ) die( "%s: empty session", name );
  JV head = JSONReader( lines[ 0 ], "session line 1" ).parse();
  const JV *w = head.get( "width" ), *h = head.get( "height" );
  if ( !w || !h ) die( "session line 1: need width and height" );
  const int width = int( w->as_ll( "width" ) ), height = int( h->as_ll( "height" ) );
  if ( width < 1 || height < 1 ) die( "session line 1: bad size" );
  return Complete( width, height );
}

static int cmd_gen( const std::string &session, const std::string &dir, bool allow_few )
{
  std::vector<std::string> lines = read_lines( session );
  Complete server = session_start( lines, session.c_str() );
  const int width = server.get_fb().ds.get_width(), height = server.get_fb().ds.get_height();
  std::vector<Complete> sent; /* sent[n] is the server's state number n */
  sent.push_back( server );
  uint64_t fake_clock = 1000;

  std::string instructions, server_lines;
  Dump prev_server = make_dump( server );
  size_t old_bases = 0, empty_diffs = 0, diff_bytes = 0;

  for ( size_t i = 1; i < lines.size(); i++ ) {
    std::string what = "session line " + num( (long long) i + 1 );
    const std::string reply = session_step( server, lines[ i ], what.c_str(), fake_clock );

    Instr in;
    in.new_num = sent.size();
    const uint64_t age = base_age( in.new_num );
    in.old_num = in.new_num - age;
    in.diff = server.diff_from( sent[ in.old_num ] );
    sent.push_back( server );

    if ( age >= 2 && age <= 8 ) old_bases++;
    if ( in.diff.empty() ) empty_diffs++;
    diff_bytes += in.diff.size();
    instructions.append( instr_json( in ) + "\n" );

    /* The server's own state after this session line, in the format of expected.jsonl. */
    Dump cur_server = make_dump( server );
    std::string server_line = delta_line( in.new_num, prev_server, cur_server );
    if ( !reply.empty() ) {
      server_line.erase( server_line.size() - 1 );
      server_line.append( ",\"reply_b64\":\"" + b64_encode( reply ) + "\"}" );
    }
    server_lines.append( server_line + "\n" );
    prev_server = cur_server;
  }

  const size_t states = sent.size() - 1;
  if ( old_bases < 3 && !allow_few ) {
    die( "%s: only %zu instructions have a base 2 to 8 states old; a case needs at least 3 "
         "(8 or more session lines)", session.c_str(), old_bases );
  }

  write_file( dir + "/meta.json", "{\"format\":" + num( FORMAT_VERSION ) + ",\"width\":" + num( width )
              + ",\"height\":" + num( height ) + "}\n" );
  write_file( dir + "/instructions.jsonl", instructions );
  write_file( dir + "/server.jsonl", server_lines );

  /* The client simulation reads back the files just written. */
  std::ostringstream expected;
  apply_dir( dir, expected, true );
  write_file( dir + "/expected.jsonl", expected.str() );

  fprintf( stderr, "%s: %zu states, %zu with an old base, %zu empty diffs, %zu diff bytes, expected.jsonl %zu bytes, "
           "server.jsonl %zu bytes\n",
           dir.c_str(), states, old_bases, empty_diffs, diff_bytes, expected.str().size(), server_lines.size() );
  return 0;
}

/* Print server.jsonl again from session.jsonl (what gen wrote), or with full = true
   the same states without the delta rule. */
static int cmd_server( const std::string &dir, bool full )
{
  std::vector<std::string> lines = read_lines( dir + "/session.jsonl" );
  Complete server = session_start( lines, "session.jsonl" );
  uint64_t fake_clock = 1000;
  Dump prev = make_dump( server );
  for ( size_t i = 1; i < lines.size(); i++ ) {
    std::string what = "session line " + num( (long long) i + 1 );
    const std::string reply = session_step( server, lines[ i ], what.c_str(), fake_clock );
    Dump cur = make_dump( server );
    std::string line = full ? full_line( i, cur ) : delta_line( i, prev, cur );
    if ( !reply.empty() ) {
      line.erase( line.size() - 1 );
      line.append( ",\"reply_b64\":\"" + b64_encode( reply ) + "\"}" );
    }
    printf( "%s\n", line.c_str() );
    prev = cur;
  }
  return 0;
}

/* ------------------------------------------------------------------ screen */

static std::string attr_names( unsigned at )
{
  static const char *names[] = { "bold", "faint", "italic", "underlined", "blink", "inverse", "invisible", "bit7" };
  std::string out;
  for ( int i = 0; i < 8; i++ ) {
    if ( at & ( 1u << i ) ) {
      if ( !out.empty() ) out.push_back( '+' );
      out.append( names[ i ] );
    }
  }
  return out.empty() ? "none" : out;
}

static std::string color_name( unsigned v, unsigned base )
{
  char buf[ 48 ];
  if ( v == 0 ) return "default";
  if ( v & 0x1000000 ) {
    snprintf( buf, sizeof buf, "rgb(%u,%u,%u)", ( v >> 16 ) & 0xff, ( v >> 8 ) & 0xff, v & 0xff );
  } else {
    snprintf( buf, sizeof buf, "palette %d", int( v ) - int( base ) );
  }
  return buf;
}

static void print_screen( const Complete &c, bool plain )
{
  const Framebuffer &fb = c.terminal.fb;
  const DrawState &ds = fb.ds;

  std::vector<std::string> text;
  for ( int y = 0; y < ds.height; y++ ) {
    std::string line;
    const Row &row = *fb.rows[ y ];
    for ( int x = 0; x < ds.width; x++ ) {
      const Cell &cell = row.cells[ x ];
      cell.print_grapheme( line );
      /* a wide character fills two columns of the reader's terminal */
      if ( cell.wide && x + 1 < ds.width && row.cells[ x + 1 ].contents.empty() ) x++;
    }
    text.push_back( line );
  }

  if ( plain ) {
    for ( size_t y = 0; y < text.size(); y++ ) printf( "%s\n", text[ y ].c_str() );
    return;
  }

  Dump d = make_dump( c );
  printf( "size %dx%d  cursor row %d col %d %s  next_print_will_wrap %s\n", ds.width, ds.height, ds.cursor_row,
          ds.cursor_col, ds.cursor_visible ? "visible" : "hidden", ds.next_print_will_wrap ? "yes" : "no" );
  std::string border( "    +" + std::string( ds.width, '-' ) + "+" );
  printf( "%s\n", border.c_str() );
  for ( int y = 0; y < ds.height; y++ ) {
    printf( "%3d |%s|%s\n", y, text[ y ].c_str(), fb.rows[ y ]->get_wrap() ? " wrap" : "" );
  }
  printf( "%s\n", border.c_str() );
  printf( "pen: fg %s, bg %s, attributes %s\n", color_name( ds.renditions.foreground_color, 30 ).c_str(),
          color_name( ds.renditions.background_color, 40 ).c_str(), attr_names( ds.renditions.attributes ).c_str() );
  for ( size_t i = 0; i < d.fields.size(); i++ ) {
    const std::string &k = d.fields[ i ].first;
    if ( k == "width" || k == "height" || k == "cursor" || k == "pen" ) continue;
    std::string v = d.fields[ i ].second;
    if ( v.size() > 200 ) v = v.substr( 0, 200 ) + "... (" + num( (long long) d.fields[ i ].second.size() ) + " bytes)";
    printf( "%s: %s\n", k.c_str(), v.c_str() );
  }
}

static size_t parse_index( const std::string &which, size_t count )
{
  if ( which == "last" ) return count;
  char *end;
  const size_t n = strtoul( which.c_str(), &end, 10 );
  if ( which.empty() || *end || n > count ) die( "screen: N must be 0..%zu or \"last\"", count );
  return n;
}

/* The client's state after instruction N (the default), or with server = true the
   server's own state after N lines of session.jsonl. */
static int cmd_screen( const std::string &dir, const std::string &which, bool plain, bool server_side )
{
  if ( server_side ) {
    std::vector<std::string> lines = read_lines( dir + "/session.jsonl" );
    Complete server = session_start( lines, "session.jsonl" );
    const size_t upto = parse_index( which, lines.size() - 1 );
    uint64_t fake_clock = 1000;
    for ( size_t i = 1; i <= upto; i++ ) {
      std::string what = "session line " + num( (long long) i + 1 );
      session_step( server, lines[ i ], what.c_str(), fake_clock );
    }
    if ( !plain ) printf( "%s: server state %zu of %zu\n", dir.c_str(), upto, lines.size() - 1 );
    print_screen( server, plain );
    return 0;
  }

  Meta meta = read_meta( dir );
  std::vector<Instr> instrs = read_instructions( dir, false );
  const size_t upto = parse_index( which, instrs.size() );
  Client client( meta.width, meta.height );
  uint64_t shown = 0, base = 0;
  for ( size_t i = 0; i < upto; i++ ) {
    client.receive( instrs[ i ] );
    shown = instrs[ i ].new_num;
    base = instrs[ i ].old_num;
  }
  if ( !plain ) {
    printf( "%s: client state after instruction %zu of %zu (state %llu, applied to state %llu)\n", dir.c_str(), upto,
            instrs.size(), (unsigned long long) shown, (unsigned long long) base );
  }
  print_screen( client.state( shown ), plain );
  return 0;
}

/* ---------------------------------------------------------------- selftest */

/* One probe: starting from a fresh 20x6 terminal, feed `setup`, take a dump, feed
   `probe`, take another dump, and require the named key to differ (for cell probes,
   "rows"; the needle must then appear in the row JSON after the probe and not
   before). */
struct Probe {
  const char *key;
  const char *what;
  const char *setup;
  const char *probe;
  const char *needle; /* substring required in the value after the probe, or NULL */
};

static std::string rows_text( const Dump &d )
{
  std::string out;
  for ( size_t i = 0; i < d.rows.size(); i++ ) out.append( d.rows[ i ] + "\n" );
  return out;
}

static std::string dump_value( const Dump &d, const std::string &key )
{
  return key == "rows" ? rows_text( d ) : d.field( key );
}

static std::string host_message( const std::string &hostbytes, int rw, int rh, long long echo )
{
  HostBuffers::HostMessage msg;
  if ( echo >= 0 ) msg.add_instruction()->MutableExtension( HostBuffers::echoack )->set_echo_ack_num( uint64_t( echo ) );
  if ( rw > 0 ) {
    HostBuffers::Instruction *in = msg.add_instruction();
    in->MutableExtension( HostBuffers::resize )->set_width( rw );
    in->MutableExtension( HostBuffers::resize )->set_height( rh );
  }
  if ( !hostbytes.empty() ) msg.add_instruction()->MutableExtension( HostBuffers::hostbytes )->set_hoststring( hostbytes );
  return msg.SerializeAsString();
}

static int cmd_selftest( void )
{
  /* \x1b is ESC, \x07 BEL. Every probe goes through Complete::apply_string, the
     only way a client state changes. Width 20, height 6. */
  static const Probe probes[] = {
    { "width", "resize 30x6", "", "@resize 30 6", "30" },
    { "height", "resize 20x9", "", "@resize 20 9", "9" },
    { "rows", "cell contents, ASCII", "", "a", "{\"t\":\"a\"}" },
    { "rows", "cell contents, non-ASCII", "", "\xc3\xa9", "{\"c\":[\"\xc3\xa9\"]}" },
    { "rows", "cell contents, base plus combining", "", "e\xcc\x81", "{\"c\":[\"e\xcc\x81\"]}" },
    { "rows", "cell foreground, 8 colours", "", "\x1b[31mx", "\"fg\":31" },
    { "rows", "cell foreground, 256 colours", "", "\x1b[38;5;200mx", "\"fg\":230" },
    { "rows", "cell foreground, true colour", "", "\x1b[38;2;1;2;3mx", "\"fg\":16843267" },
    { "rows", "cell background, 8 colours", "", "\x1b[42mx", "\"bg\":42" },
    { "rows", "cell background, 256 colours", "", "\x1b[48;5;200mx", "\"bg\":240" },
    { "rows", "cell background, true colour", "", "\x1b[48;2;1;2;3mx", "\"bg\":16843267" },
    { "rows", "erased cell keeps the background", "", "\x1b[44m\x1b[K", "{\"e\":20,\"bg\":44}" },
    { "rows", "cell attribute bold", "", "\x1b[1mx", "\"at\":1}" },
    { "rows", "cell attribute italic", "", "\x1b[3mx", "\"at\":4}" },
    { "rows", "cell attribute underlined", "", "\x1b[4mx", "\"at\":8}" },
    { "rows", "cell attribute blink", "", "\x1b[5mx", "\"at\":16}" },
    { "rows", "cell attribute inverse", "", "\x1b[7mx", "\"at\":32}" },
    { "rows", "cell attribute invisible", "", "\x1b[8mx", "\"at\":64}" },
    { "rows", "cell wide", "", "\xe6\xbc\xa2", "\"wide\":true" },
    { "rows", "cell fallback", "", "\xcc\x81", "\"fallback\":true" },
    { "rows", "cell wrap", "aaaaaaaaaaaaaaaaaaaa", "b", "\"wrap\":true" },
    { "cursor", "cursor row and column", "", "\x1b[3;7H", "[2,6]" },
    { "combining", "combining cell follows a print", "", "ab", "[0,1]" },
    { "combining", "combining cell lost by a resize", "\x1b[6;20Hx", "@resize 10 3", "[-1,-1]" },
    { "default_tabs", "TBC 3", "", "\x1b[3g", "false" },
    { "tabs", "HTS at column 3", "\x1b[1;4H", "\x1bH", "[0,3,8,16]" },
    { "scroll_region", "DECSTBM 2;5", "", "\x1b[2;5r", "[1,4]" },
    { "pen", "pen foreground", "", "\x1b[35m", "{\"fg\":35}" },
    { "pen", "pen background", "", "\x1b[45m", "{\"bg\":45}" },
    { "pen", "pen attributes", "", "\x1b[1;4m", "{\"at\":9}" },
    { "saved", "saved cursor position", "\x1b[3;7H", "\x1b""7", "\"cursor\":[2,6]" },
    { "saved", "saved pen", "\x1b[1;31;42m", "\x1b""7", "\"pen\":{\"fg\":31,\"bg\":42,\"at\":1}" },
    { "saved", "saved auto wrap mode", "\x1b[?7l", "\x1b""7", "\"auto_wrap_mode\":false" },
    { "saved", "saved origin mode", "\x1b[?6h", "\x1b""7", "\"origin_mode\":true" },
    { "next_print_will_wrap", "print in the last column", "aaaaaaaaaaaaaaaaaaa", "a", "true" },
    { "origin_mode", "DECSET 6", "", "\x1b[?6h", "true" },
    { "auto_wrap_mode", "DECRST 7", "", "\x1b[?7l", "false" },
    { "insert_mode", "SM 4", "", "\x1b[4h", "true" },
    { "cursor_visible", "DECRST 25", "", "\x1b[?25l", "false" },
    { "reverse_video", "DECSET 5", "", "\x1b[?5h", "true" },
    { "bracketed_paste", "DECSET 2004", "", "\x1b[?2004h", "true" },
    { "mouse_reporting_mode", "DECSET 9", "", "\x1b[?9h", "9" },
    { "mouse_reporting_mode", "DECSET 1000", "", "\x1b[?1000h", "1000" },
    { "mouse_reporting_mode", "DECSET 1001", "", "\x1b[?1001h", "1001" },
    { "mouse_reporting_mode", "DECSET 1002", "", "\x1b[?1002h", "1002" },
    { "mouse_reporting_mode", "DECSET 1003", "", "\x1b[?1003h", "1003" },
    { "mouse_focus_event", "DECSET 1004", "", "\x1b[?1004h", "true" },
    { "mouse_alternate_scroll", "DECSET 1007", "", "\x1b[?1007h", "true" },
    { "mouse_encoding_mode", "DECSET 1005", "", "\x1b[?1005h", "1005" },
    { "mouse_encoding_mode", "DECSET 1006", "", "\x1b[?1006h", "1006" },
    { "mouse_encoding_mode", "DECSET 1015", "", "\x1b[?1015h", "1015" },
    { "application_mode_cursor_keys", "DECSET 1", "", "\x1b[?1h", "true" },
    { "icon_name", "OSC 1", "", "\x1b]1;icon\x07", "\"icon\"" },
    { "window_title", "OSC 2", "", "\x1b]2;title\x07", "\"title\"" },
    { "title_initialized", "OSC 0", "", "\x1b]0;x\x07", "true" },
    { "clipboard", "OSC 52", "", "\x1b]52;c;aGk=\x07", "\"aGk=\"" },
    { "bell_count", "BEL", "", "\x07", "1" },
    { "echo_ack", "EchoAck instruction", "", "@echo 7", "7" },
    { "parser_state", "Escape", "", "\x1b", "\"Escape\"" },
    { "parser_state", "Escape_Intermediate", "", "\x1b(", "\"Escape_Intermediate\"" },
    { "parser_state", "CSI_Entry", "", "\x1b[", "\"CSI_Entry\"" },
    { "parser_state", "CSI_Param", "", "\x1b[1", "\"CSI_Param\"" },
    { "parser_state", "CSI_Intermediate", "", "\x1b[ ", "\"CSI_Intermediate\"" },
    { "parser_state", "CSI_Ignore", "", "\x1b[:", "\"CSI_Ignore\"" },
    { "parser_state", "DCS_Entry", "", "\x1bP", "\"DCS_Entry\"" },
    { "parser_state", "DCS_Param", "", "\x1bP1", "\"DCS_Param\"" },
    { "parser_state", "DCS_Intermediate", "", "\x1bP ", "\"DCS_Intermediate\"" },
    { "parser_state", "DCS_Passthrough", "", "\x1bPq", "\"DCS_Passthrough\"" },
    { "parser_state", "DCS_Ignore", "", "\x1bP:", "\"DCS_Ignore\"" },
    { "parser_state", "OSC_String", "", "\x1b]", "\"OSC_String\"" },
    { "parser_state", "SOS_PM_APC_String", "", "\x1b_", "\"SOS_PM_APC_String\"" },
    { "parser_state", "back to Ground", "\x1b[", "m", "\"Ground\"" },
    { "utf8_buf", "first byte of a three-byte character", "", "\xe2", "[226]" },
    { "utf8_buf", "two bytes of a three-byte character", "", "\xe2\x94", "[226,148]" },
    { "params", "CSI parameters", "", "\x1b[12;3", "\"12;3\"" },
    { "dispatch_chars", "CSI private marker", "", "\x1b[?", "[63]" },
    { "dispatch_chars", "final character stays after dispatch", "", "\x1b[?25h", "[63,104]" },
    { "parsed", "parameters parsed by a dispatch", "", "\x1b[5;7H", "true" },
    { "parsed_params", "parameters parsed by a dispatch", "", "\x1b[5;7H", "[5,7]" },
    { "osc_string", "OSC string in progress", "", "\x1b]0;ab", "\"0;ab\"" },
  };

  std::set<std::string> covered;
  int failures = 0;
  const size_t count = sizeof probes / sizeof probes[ 0 ];
  for ( size_t i = 0; i < count; i++ ) {
    const Probe &p = probes[ i ];
    Complete c( 20, 6 );
    if ( *p.setup ) c.apply_string( host_message( p.setup, 0, 0, -1 ) );
    Dump before = make_dump( c );
    int a = 0, b = 0;
    if ( sscanf( p.probe, "@resize %d %d", &a, &b ) == 2 ) {
      c.apply_string( host_message( "", a, b, -1 ) );
    } else if ( sscanf( p.probe, "@echo %d", &a ) == 1 ) {
      c.apply_string( host_message( "", 0, 0, a ) );
    } else {
      c.apply_string( host_message( p.probe, 0, 0, -1 ) );
    }
    Dump after = make_dump( c );
    const std::string v0 = dump_value( before, p.key ), v1 = dump_value( after, p.key );
    bool ok = v0 != v1;
    if ( ok && p.needle ) ok = v1.find( p.needle ) != std::string::npos && v0.find( p.needle ) == std::string::npos;
    /* the change must also reach the delta line */
    const std::string line = delta_line( 1, before, after );
    if ( ok ) ok = line.find( "\"" + std::string( p.key ) + "\":" ) != std::string::npos;
    printf( "%s  %-30s %s\n", ok ? "PASS" : "FAIL", p.key, p.what );
    if ( !ok ) {
      failures++;
      printf( "      before: %s\n      after:  %s\n", v0.c_str(), v1.c_str() );
    }
    covered.insert( p.key );
  }

  /* Every key the dump can print must have a probe. */
  Dump fresh = make_dump( Complete( 20, 6 ) );
  for ( size_t i = 0; i < fresh.fields.size(); i++ ) {
    if ( !covered.count( fresh.fields[ i ].first ) ) {
      printf( "FAIL  %-30s no probe for this key\n", fresh.fields[ i ].first.c_str() );
      failures++;
    }
  }
  if ( !covered.count( "rows" ) ) failures++;

  /* A fresh state must dump to the documented initial values (FORMAT.md). */
  static const char *initial[][ 2 ] = {
    { "width", "20" }, { "height", "6" }, { "cursor", "[0,0]" }, { "combining", "[0,0]" },
    { "default_tabs", "true" }, { "tabs", "[0,8,16]" }, { "scroll_region", "[0,5]" }, { "pen", "{}" },
    { "saved", "{\"cursor\":[0,0],\"pen\":{},\"auto_wrap_mode\":true,\"origin_mode\":false}" },
    { "next_print_will_wrap", "false" }, { "origin_mode", "false" }, { "auto_wrap_mode", "true" },
    { "insert_mode", "false" }, { "cursor_visible", "true" }, { "reverse_video", "false" },
    { "bracketed_paste", "false" }, { "mouse_reporting_mode", "0" }, { "mouse_focus_event", "false" },
    { "mouse_alternate_scroll", "false" }, { "mouse_encoding_mode", "0" },
    { "application_mode_cursor_keys", "false" }, { "icon_name", "\"\"" }, { "window_title", "\"\"" },
    { "title_initialized", "false" }, { "clipboard", "\"\"" }, { "bell_count", "0" }, { "echo_ack", "0" },
    { "parser_state", "\"Ground\"" }, { "utf8_buf", "[]" }, { "params", "\"\"" }, { "dispatch_chars", "[]" },
    { "parsed", "false" }, { "parsed_params", "[]" }, { "osc_string", "\"\"" },
  };
  const size_t initial_count = sizeof initial / sizeof initial[ 0 ];
  if ( initial_count != fresh.fields.size() ) {
    printf( "FAIL  initial value table has %zu keys, the dump has %zu\n", initial_count, fresh.fields.size() );
    failures++;
  }
  for ( size_t i = 0; i < initial_count; i++ ) {
    if ( fresh.field( initial[ i ][ 0 ] ) != initial[ i ][ 1 ] ) {
      printf( "FAIL  initial value of %s is %s, documented as %s\n", initial[ i ][ 0 ],
              fresh.field( initial[ i ][ 0 ] ).c_str(), initial[ i ][ 1 ] );
      failures++;
    }
  }
  for ( size_t y = 0; y < fresh.rows.size(); y++ ) {
    if ( fresh.rows[ y ] != "[{\"e\":20}]" ) {
      printf( "FAIL  initial row %zu is %s\n", y, fresh.rows[ y ].c_str() );
      failures++;
    }
  }

  printf( "%zu probes, %zu keys plus rows, %d failures\n", count, fresh.fields.size(), failures );
  return failures ? 1 : 0;
}

/* ----------------------------------------------------------------- respond */

/* Co-process for scripts/pty-record.py. It plays the part of mosh-server's terminal
   towards the recorded program: for each chunk of pty output it prints the bytes
   the terminal answers (DA, DSR), which the recorder writes back to the pty.
   Input lines: "B <base64>" or "R <w> <h>". Output: one base64 line per input line. */
static int cmd_respond( int width, int height )
{
  Complete term( width, height );
  std::string line;
  while ( std::getline( std::cin, line ) ) {
    std::string reply;
    if ( line.size() >= 2 && line[ 0 ] == 'B' && line[ 1 ] == ' ' ) {
      reply = term.act( b64_decode( line.substr( 2 ) ) );
    } else if ( line.size() >= 2 && line[ 0 ] == 'R' && line[ 1 ] == ' ' ) {
      int w = 0, h = 0;
      if ( sscanf( line.c_str() + 2, "%d %d", &w, &h ) != 2 || w < 1 || h < 1 ) die( "respond: bad resize" );
      term.act( Parser::Resize( size_t( w ), size_t( h ) ) );
    } else {
      die( "respond: bad line" );
    }
    printf( "%s\n", b64_encode( reply ).c_str() );
    fflush( stdout );
  }
  return 0;
}

/* ------------------------------------------------- shared with predict.cc */

std::string oracle_state_line( uint64_t num, const Complete &c ) { return full_line( num, make_dump( c ) ); }
std::string oracle_rend_object( const Renditions &r ) { return rend_object( r ); }
const char *oracle_parser_state_name( const Parser::State *s ) { return parser_state_name( s ); }
std::string oracle_b64( const std::string &in ) { return b64_encode( in ); }

/* -------------------------------------------------------------------- main */

static int usage( void )
{
  fprintf( stderr,
           "usage: mosh-oracle gen --session FILE --out DIR [--allow-few-old-bases]\n"
           "       mosh-oracle apply DIR [--no-verify-ops] [--full]\n"
           "       mosh-oracle server DIR [--full]\n"
           "       mosh-oracle screen DIR N|last [--plain] [--server]\n"
           "       mosh-oracle selftest\n"
           "       mosh-oracle respond WIDTH HEIGHT\n"
           "       mosh-oracle predict < COMMANDS\n" );
  return 64;
}

int main( int argc, char *argv[] )
{
  /* mosh's parser and wcwidth() need a UTF-8 locale. The corpus is defined with
     glibc's en_US.UTF-8 tables. */
  if ( !setlocale( LC_ALL, "en_US.UTF-8" ) ) {
    die( "the en_US.UTF-8 locale is not installed" );
  }

  std::vector<std::string> args( argv + 1, argv + argc );
  if ( args.empty() ) return usage();
  const std::string mode = args[ 0 ];

  if ( mode == "gen" ) {
    std::string session, out;
    bool allow_few = false;
    for ( size_t i = 1; i < args.size(); i++ ) {
      if ( args[ i ] == "--session" && i + 1 < args.size() ) session = args[ ++i ];
      else if ( args[ i ] == "--out" && i + 1 < args.size() ) out = args[ ++i ];
      else if ( args[ i ] == "--allow-few-old-bases" ) allow_few = true;
      else return usage();
    }
    if ( session.empty() || out.empty() ) return usage();
    return cmd_gen( session, out, allow_few );
  }
  if ( mode == "apply" ) {
    if ( args.size() < 2 ) return usage();
    bool verify = true, full = false;
    for ( size_t i = 2; i < args.size(); i++ ) {
      if ( args[ i ] == "--no-verify-ops" ) verify = false;
      else if ( args[ i ] == "--full" ) full = true;
      else return usage();
    }
    apply_dir( args[ 1 ], std::cout, verify, full );
    return 0;
  }
  if ( mode == "server" ) {
    if ( args.size() < 2 || args.size() > 3 ) return usage();
    if ( args.size() == 3 && args[ 2 ] != "--full" ) return usage();
    return cmd_server( args[ 1 ], args.size() == 3 );
  }
  if ( mode == "screen" ) {
    if ( args.size() < 3 ) return usage();
    bool plain = false, server_side = false;
    for ( size_t i = 3; i < args.size(); i++ ) {
      if ( args[ i ] == "--plain" ) plain = true;
      else if ( args[ i ] == "--server" ) server_side = true;
      else return usage();
    }
    return cmd_screen( args[ 1 ], args[ 2 ], plain, server_side );
  }
  if ( mode == "selftest" ) {
    return cmd_selftest();
  }
  if ( mode == "predict" ) {
    if ( args.size() != 1 ) return usage();
    return predict_main();
  }
  if ( mode == "respond" ) {
    if ( args.size() != 3 ) return usage();
    return cmd_respond( atoi( args[ 1 ].c_str() ), atoi( args[ 2 ].c_str() ) );
  }
  return usage();
}

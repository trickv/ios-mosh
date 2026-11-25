/*
 * moshref: drives mosh 1.4.0's own Terminal::Complete and prints its whole state in the
 * format of MoshTerminal's TerminalState.debugDump() (see Sources/MoshTerminal/DebugDump.swift,
 * keep the two in step). MoshCrossCheckTests feeds the same operations to the Swift port
 * and compares the text.
 *
 * Linux only; links the static libraries of the built mosh tree (/opt/mosh-src in the
 * dev container). Build with build-moshref.sh.
 *
 * Commands on stdin, one per line:
 *   new W H         start a fresh Complete( W, H )
 *   bytes HEX       Complete::act( string )               (what apply_string does for hostbytes)
 *   resize W H      Complete::act( Parser::Resize( W, H ) )  (... for resize)
 *   echoack N       echo_ack = N                             (... for echoack)
 *   userbytes HEX   Complete::act( Parser::UserByte( c ) ) for each byte (server side)
 *   save            keep a copy of the current Complete (as a client keeps older states)
 *   drop            forget that copy
 *   dump            print the state, then "=== end"
 *   cmp             print "cmp mosh_eq=B same_rows=[B...]" against the saved copy, then "=== end":
 *                   mosh's Complete::operator== and, per line, whether both hold the same Row object
 *   reply           print "reply [HEX]" (terminal-to-host bytes since the last "reply"), then "=== end"
 *   diff I [E B T]  print "diff [HEX]", then "=== end": Display::new_frame( I, saved.fb, current.fb )
 *                   with the Display of Complete (Display( false )). I is 0 or 1. The optional
 *                   E B T (0 or 1 each) override has_ech, has_bce and has_title.
 *   applydiff I     what a client does with a diff: copy the saved state, resize the copy if the
 *                   sizes differ, feed it new_frame( I, saved.fb, current.fb ), and make the copy
 *                   the current state. The reply to the host goes to "reply".
 *
 * The private members of mosh's classes are read through "#define private public".
 * That does not change the layout of the classes with GCC, so the prebuilt libraries fit.
 */
#include <assert.h>
#include <limits.h>
#include <stdarg.h>
#include <locale.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include <deque>
#include <iostream>
#include <list>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <typeinfo>
#include <vector>

#define private public
#define protected public
#include "completeterminal.h"
#undef private
#undef protected

using namespace Terminal;

static std::string out;

static void put( const std::string &s ) { out += s; }

static void putf( const char *fmt, ... ) __attribute__(( format( printf, 1, 2 ) ));
static void putf( const char *fmt, ... )
{
  char buf[ 512 ];
  va_list ap;
  va_start( ap, fmt );
  vsnprintf( buf, sizeof buf, fmt, ap );
  va_end( ap );
  out += buf;
}

static std::string hex( const std::string &s )
{
  static const char digits[] = "0123456789abcdef";
  std::string r;
  for ( size_t i = 0; i < s.size(); i++ ) {
    unsigned char c = s[ i ];
    r.push_back( digits[ c >> 4 ] );
    r.push_back( digits[ c & 15 ] );
  }
  return r;
}

static std::string unhex( const std::string &s )
{
  std::string r;
  assert( s.size() % 2 == 0 );
  for ( size_t i = 0; i + 1 < s.size(); i += 2 ) {
    r.push_back( (char) strtol( s.substr( i, 2 ).c_str(), NULL, 16 ) );
  }
  return r;
}

static std::string title( const std::vector<wchar_t> &t )
{
  char buf[ 64 ];
  snprintf( buf, sizeof buf, "len=%zu \"", t.size() );
  std::string r( buf );
  for ( size_t i = 0; i < t.size(); i++ ) {
    uint32_t c = t[ i ];
    if ( c >= 0x20 && c <= 0x7E && c != 0x22 && c != 0x5C ) {
      r.push_back( (char) c );
    } else {
      snprintf( buf, sizeof buf, "\\u{%X}", c );
      r += buf;
    }
  }
  r += "\"";
  return r;
}

static std::string renditions( const Renditions &r )
{
  char buf[ 128 ];
  snprintf( buf, sizeof buf, "fg=%u bg=%u attrs=%02x",
	    (unsigned) r.foreground_color, (unsigned) r.background_color, (unsigned) r.attributes );
  return buf;
}

static const char *state_name( const Parser::State *s )
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
  return "?";
}

static std::string cell_text( const Cell &c )
{
  std::string flags;
  if ( c.wide ) flags += "w";
  if ( c.fallback ) flags += "f";
  if ( c.wrap ) flags += "r";
  if ( flags.empty() ) flags = "-";
  char buf[ 128 ];
  snprintf( buf, sizeof buf, ":%u:%u:%02x:",
	    (unsigned) c.renditions.foreground_color, (unsigned) c.renditions.background_color,
	    (unsigned) c.renditions.attributes );
  return ( c.contents.empty() ? std::string( "-" ) : hex( c.contents ) ) + buf + flags;
}

static void dump_fb( const Framebuffer &fb )
{
  const DrawState &ds = fb.ds;
  putf( "fb width=%d height=%d bell_count=%u title_initialized=%d\n",
	ds.width, ds.height, fb.bell_count, fb.title_initialized ? 1 : 0 );
  put( "icon_name " + title( fb.icon_name ) + "\n" );
  put( "window_title " + title( fb.window_title ) + "\n" );
  put( "clipboard " + title( fb.clipboard ) + "\n" );
  putf( "cursor row=%d col=%d combining_row=%d combining_col=%d\n",
	ds.cursor_row, ds.cursor_col, ds.combining_char_row, ds.combining_char_col );
  putf( "scrolling_region top=%d bottom=%d\n", ds.scrolling_region_top_row, ds.scrolling_region_bottom_row );
  putf( "tabs default=%d stops=[", ds.default_tabs ? 1 : 0 );
  bool first = true;
  for ( size_t i = 0; i < ds.tabs.size(); i++ ) {
    if ( ds.tabs[ i ] ) {
      putf( "%s%zu", first ? "" : ",", i );
      first = false;
    }
  }
  put( "]\n" );
  put( "pen " + renditions( ds.renditions ) + "\n" );
  putf( "saved cursor_row=%d cursor_col=%d auto_wrap=%d origin=%d ",
	ds.save.cursor_row, ds.save.cursor_col, ds.save.auto_wrap_mode ? 1 : 0, ds.save.origin_mode ? 1 : 0 );
  put( renditions( ds.save.renditions ) + "\n" );
  putf( "modes next_print_will_wrap=%d origin=%d auto_wrap=%d insert=%d cursor_visible=%d"
	" reverse_video=%d bracketed_paste=%d mouse_reporting=%d mouse_focus_event=%d"
	" mouse_alternate_scroll=%d mouse_encoding=%d application_cursor_keys=%d\n",
	ds.next_print_will_wrap ? 1 : 0, ds.origin_mode ? 1 : 0, ds.auto_wrap_mode ? 1 : 0,
	ds.insert_mode ? 1 : 0, ds.cursor_visible ? 1 : 0, ds.reverse_video ? 1 : 0,
	ds.bracketed_paste ? 1 : 0, (int) ds.mouse_reporting_mode, ds.mouse_focus_event ? 1 : 0,
	ds.mouse_alternate_scroll ? 1 : 0, (int) ds.mouse_encoding_mode,
	ds.application_mode_cursor_keys ? 1 : 0 );

  const Framebuffer::rows_type &rows = fb.rows;
  for ( size_t y = 0; y < rows.size(); y++ ) {
    const Row &row = *rows[ y ];
    size_t obj = y, gen = y;
    for ( size_t k = 0; k < y; k++ ) { if ( rows[ k ].get() == rows[ y ].get() ) { obj = k; break; } }
    for ( size_t k = 0; k < y; k++ ) { if ( rows[ k ]->gen == row.gen ) { gen = k; break; } }

    /* what the display would print: one grapheme per cell, skipping the cell after a wide one */
    std::string bytes;
    for ( size_t x = 0; x < row.cells.size(); x += row.cells[ x ].get_width() ) {
      row.cells[ x ].print_grapheme( bytes );
    }
    std::string text;
    for ( size_t i = 0; i < bytes.size(); i++ ) {
      unsigned char b = bytes[ i ];
      if ( b >= 0x20 && b <= 0x7E && b != 0x22 && b != 0x5C ) {
	text.push_back( (char) b );
      } else {
	char buf[ 8 ];
	snprintf( buf, sizeof buf, "\\x%02X", b );
	text += buf;
      }
    }
    putf( "row %zu obj=%zu gen=%zu wrap=%d text=\"", y, obj, gen, row.get_wrap() ? 1 : 0 );
    put( text + "\"\n  " );

    bool firstcell = true;
    for ( size_t i = 0; i < row.cells.size(); ) {
      size_t j = i + 1;
      while ( j < row.cells.size() && row.cells[ j ] == row.cells[ i ] ) j++;
      if ( !firstcell ) put( " " );
      firstcell = false;
      if ( j - i > 1 ) putf( "%zu*", j - i );
      put( cell_text( row.cells[ i ] ) );
      i = j;
    }
    put( "\n" );
  }
}

static void dump( const Complete &c )
{
  putf( "complete echo_ack=%llu input_history=[", (unsigned long long) c.echo_ack );
  bool first = true;
  for ( Complete::input_history_type::const_iterator i = c.input_history.begin(); i != c.input_history.end(); i++ ) {
    putf( "%s%llu@%llu", first ? "" : ",", (unsigned long long) i->first, (unsigned long long) i->second );
    first = false;
  }
  put( "]\n" );
  putf( "parser state=%s utf8_buf=[", state_name( c.parser.parser.state ) );
  put( hex( std::string( c.parser.buf, c.parser.buf_len ) ) + "]\n" );

  const Dispatcher &d = c.terminal.dispatch;
  put( "dispatch params=\"" + d.params + "\"" );
  putf( " parsed=%d parsed_params=[", d.parsed ? 1 : 0 );
  for ( size_t i = 0; i < d.parsed_params.size(); i++ ) {
    putf( "%s%d", i ? "," : "", d.parsed_params[ i ] );
  }
  put( "] dispatch_chars=[" + hex( d.dispatch_chars ) + "] terminal_to_host=[" + hex( d.terminal_to_host ) + "]\n" );
  put( "osc_string " + title( d.OSC_string ) + "\n" );
  const char *user = "?";
  switch ( c.terminal.user.state ) {
  case UserInput::Ground: user = "Ground"; break;
  case UserInput::ESC: user = "ESC"; break;
  case UserInput::SS3: user = "SS3"; break;
  }
  putf( "user state=%s\n", user );
  dump_fb( c.terminal.fb );
}

int main( void )
{
  if ( !setlocale( LC_ALL, "en_US.UTF-8" ) ) {
    fprintf( stderr, "moshref: locale en_US.UTF-8 is not available\n" );
    return 1;
  }

  std::unique_ptr<Complete> cur( new Complete( 80, 24 ) );
  std::unique_ptr<Complete> saved;
  std::string reply;
  std::string line;

  while ( std::getline( std::cin, line ) ) {
    std::istringstream in( line );
    std::string cmd;
    in >> cmd;
    if ( cmd.empty() || cmd[ 0 ] == '#' ) {
      continue;
    } else if ( cmd == "new" ) {
      int w, h;
      in >> w >> h;
      saved.reset();
      cur.reset( new Complete( w, h ) );
      reply.clear();
    } else if ( cmd == "bytes" ) {
      std::string h;
      in >> h;
      reply += cur->act( unhex( h ) );
    } else if ( cmd == "resize" ) {
      int w, h;
      in >> w >> h;
      reply += cur->act( Parser::Resize( w, h ) );
    } else if ( cmd == "echoack" ) {
      unsigned long long n;
      in >> n;
      cur->echo_ack = n;
    } else if ( cmd == "userbytes" ) {
      std::string h;
      in >> h;
      std::string b = unhex( h );
      for ( size_t i = 0; i < b.size(); i++ ) {
	reply += cur->act( Parser::UserByte( b[ i ] ) );
      }
    } else if ( cmd == "save" ) {
      saved.reset( new Complete( *cur ) );
    } else if ( cmd == "drop" ) {
      saved.reset();
    } else if ( cmd == "dump" ) {
      dump( *cur );
      put( "=== end\n" );
    } else if ( cmd == "cmp" ) {
      if ( !saved ) {
	put( "cmp no saved state\n=== end\n" );
      } else {
	putf( "cmp mosh_eq=%d same_rows=[", ( *cur == *saved ) ? 1 : 0 );
	const Framebuffer::rows_type &a = cur->terminal.fb.rows;
	const Framebuffer::rows_type &b = saved->terminal.fb.rows;
	for ( size_t y = 0; y < a.size() && y < b.size(); y++ ) {
	  put( a[ y ].get() == b[ y ].get() ? "1" : "0" );
	}
	put( "]\n=== end\n" );
      }
    } else if ( cmd == "diff" || cmd == "applydiff" ) {
      int initialized = 1, ech = 1, bce = 1, title = 1;
      in >> initialized;
      int e, b, t;
      if ( cmd == "diff" && ( in >> e >> b >> t ) ) {
	ech = e;
	bce = b;
	title = t;
      }
      if ( !saved ) {
	fprintf( stderr, "moshref: %s without a saved state\n", cmd.c_str() );
	return 2;
      }
      Display display( false );
      display.has_ech = ech;
      display.has_bce = bce;
      display.has_title = title;
      const std::string update = display.new_frame( initialized, saved->terminal.fb, cur->terminal.fb );
      if ( cmd == "diff" ) {
	put( "diff [" + hex( update ) + "]\n=== end\n" );
      } else {
	std::unique_ptr<Complete> next( new Complete( *saved ) );
	const int w = cur->terminal.fb.ds.get_width(), h = cur->terminal.fb.ds.get_height();
	if ( w != saved->terminal.fb.ds.get_width() || h != saved->terminal.fb.ds.get_height() ) {
	  reply += next->act( Parser::Resize( w, h ) );
	}
	reply += next->act( update );
	cur.reset( next.release() );
      }
    } else if ( cmd == "reply" ) {
      put( "reply [" + hex( reply ) + "]\n=== end\n" );
      reply.clear();
    } else {
      fprintf( stderr, "moshref: unknown command: %s\n", cmd.c_str() );
      return 2;
    }
    if ( out.size() > ( 1 << 16 ) ) {
      fwrite( out.data(), 1, out.size(), stdout );
      out.clear();
    }
  }
  fwrite( out.data(), 1, out.size(), stdout );
  return 0;
}

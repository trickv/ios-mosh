/*
 * mosh-oracle predict: mosh 1.4.0's own prediction engine (frontend/terminaloverlay.o,
 * the object mosh-client is linked from) driven by a command stream, for the
 * differential test of the Swift port (docs/notes/m10/DESIGN.md 7.1, FORMAT.md 11).
 *
 * The engine's only clock is Network::timestamp() (network.h:54). It is defined here and
 * returns the value of the last "time" command, so network.o is never linked (a second
 * definition would fail the link, not be picked silently).
 *
 * Every command prints exactly one line on stdout. A bad command prints
 * {"error":"..."} and exits 65.
 *
 * Licensed like mosh (GPLv3+), which it links.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <iostream>
#include <list>
#include <string>
#include <vector>

#include "completeterminal.h"
#include "parser.h"
#include "terminaloverlay.h"
#include "oracle.h"

using Overlay::ConditionalCursorMove;
using Overlay::ConditionalOverlayCell;
using Overlay::ConditionalOverlayRow;
using Overlay::PredictionEngine;
using Terminal::Cell;
using Terminal::Complete;
using Terminal::Framebuffer;

static uint64_t oracle_now = 0;

namespace Network {
  uint64_t timestamp( void ) { return oracle_now; }
}

static void fail( const std::string &why ) __attribute__(( noreturn ));
static void fail( const std::string &why )
{
  std::string out;
  for ( size_t i = 0; i < why.size(); i++ ) {
    char c = why[ i ];
    if ( c == '"' || c == '\\' ) out.push_back( '\\' );
    out.push_back( ( uint8_t( c ) < 0x20 ) ? ' ' : c );
  }
  printf( "{\"error\":\"%s\"}\n", out.c_str() );
  fflush( stdout );
  exit( 65 );
}

static std::string u( uint64_t v )
{
  char buf[ 32 ];
  snprintf( buf, sizeof buf, "\"%llu\"", (unsigned long long) v );
  return buf;
}

static std::string n( long long v )
{
  char buf[ 32 ];
  snprintf( buf, sizeof buf, "%lld", v );
  return buf;
}

static std::string b( bool v ) { return v ? "true" : "false"; }

static std::string hex( const char *p, size_t len )
{
  static const char D[] = "0123456789abcdef";
  std::string out;
  for ( size_t i = 0; i < len; i++ ) {
    uint8_t c = uint8_t( p[ i ] );
    out.push_back( D[ c >> 4 ] );
    out.push_back( D[ c & 15 ] );
  }
  return out;
}

static std::string unhex( const std::string &s )
{
  if ( s.size() % 2 ) fail( "odd hex length" );
  std::string out;
  for ( size_t i = 0; i < s.size(); i += 2 ) {
    int v = 0;
    for ( int k = 0; k < 2; k++ ) {
      char c = s[ i + k ];
      int d;
      if ( c >= '0' && c <= '9' ) d = c - '0';
      else if ( c >= 'a' && c <= 'f' ) d = c - 'a' + 10;
      else fail( "bad hex digit" );
      v = v * 16 + d;
    }
    out.push_back( char( v ) );
  }
  return out;
}

static uint64_t unsigned_arg( const std::string &s )
{
  if ( s.empty() || s.size() > 20 ) fail( "bad number" );
  uint64_t v = 0;
  for ( size_t i = 0; i < s.size(); i++ ) {
    if ( s[ i ] < '0' || s[ i ] > '9' ) fail( "bad number" );
    uint64_t d = uint64_t( s[ i ] - '0' );
    if ( v > ( UINT64_MAX - d ) / 10 ) fail( "number out of range" );
    v = v * 10 + d;
  }
  return v;
}

static int size_arg( const std::string &s )
{
  uint64_t v = unsigned_arg( s );
  if ( v < 1 || v > 1000 ) fail( "size out of range" );
  return int( v );
}

static const char *display_name( PredictionEngine::DisplayPreference d )
{
  switch ( d ) {
  case PredictionEngine::Always: return "always";
  case PredictionEngine::Never: return "never";
  case PredictionEngine::Adaptive: return "adaptive";
  case PredictionEngine::Experimental: return "experimental";
  }
  fail( "internal: unknown display preference" );
}

/* {"c":"base64 contents","r":RENDITIONS,"w":B,"f":B,"x":B} */
static std::string cell_json( const Cell &c )
{
  return "{\"c\":\"" + oracle_b64( c.contents ) + "\",\"r\":" + oracle_rend_object( c.renditions )
    + ",\"w\":" + b( c.wide ) + ",\"f\":" + b( c.fallback ) + ",\"x\":" + b( c.wrap ) + "}";
}

static std::string engine_json( const PredictionEngine &e )
{
  std::string o = "{";
  o += "\"prediction_epoch\":" + u( e.prediction_epoch );
  o += ",\"confirmed_epoch\":" + u( e.confirmed_epoch );
  o += ",\"flagging\":" + b( e.flagging );
  o += ",\"srtt_trigger\":" + b( e.srtt_trigger );
  o += ",\"glitch_trigger\":" + n( e.glitch_trigger );
  o += ",\"last_quick_confirmation\":" + u( e.last_quick_confirmation );
  o += ",\"send_interval\":" + n( e.send_interval );
  o += ",\"last_height\":" + n( e.last_height );
  o += ",\"last_width\":" + n( e.last_width );
  o += ",\"local_frame_sent\":" + u( e.local_frame_sent );
  o += ",\"local_frame_acked\":" + u( e.local_frame_acked );
  o += ",\"local_frame_late_acked\":" + u( e.local_frame_late_acked );
  /* char, signed on x86-64; the port holds UInt8 and the engine only compares it for
     equality (toc:666-670), so it is printed unsigned. */
  o += ",\"last_byte\":" + n( (unsigned char) e.last_byte );
  o += ",\"parser_state\":\"" + std::string( oracle_parser_state_name( e.parser.parser.state ) ) + "\"";
  o += ",\"parser_buf\":\"" + hex( e.parser.buf, e.parser.buf_len ) + "\"";
  o += ",\"display\":\"" + std::string( display_name( e.display_preference ) ) + "\"";
  o += ",\"overwrite\":" + b( e.predict_overwrite );
  o += ",\"active\":" + b( e.active() );
  o += ",\"wait_time\":" + n( e.wait_time() );

  o += ",\"cursors\":[";
  bool first = true;
  for ( std::list<ConditionalCursorMove>::const_iterator i = e.cursors.begin(); i != e.cursors.end(); i++ ) {
    if ( !first ) o += ",";
    first = false;
    o += "[" + u( i->expiration_frame ) + "," + n( i->row ) + "," + n( i->col ) + "," + b( i->active ) + ","
      + u( i->tentative_until_epoch ) + "," + u( i->prediction_time ) + "]";
  }
  o += "]";

  o += ",\"overlays\":[";
  first = true;
  for ( std::list<ConditionalOverlayRow>::const_iterator r = e.overlays.begin(); r != e.overlays.end(); r++ ) {
    if ( !first ) o += ",";
    first = false;
    o += "{\"row\":" + n( r->row_num ) + ",\"cells\":[";
    for ( size_t k = 0; k < r->overlay_cells.size(); k++ ) {
      const ConditionalOverlayCell &c = r->overlay_cells[ k ];
      if ( k ) o += ",";
      o += "[" + n( c.col ) + "," + b( c.active ) + "," + u( c.expiration_frame ) + ","
        + u( c.tentative_until_epoch ) + "," + u( c.prediction_time ) + "," + b( c.unknown ) + ","
        + cell_json( c.replacement ) + ",[";
      for ( size_t m = 0; m < c.original_contents.size(); m++ ) {
        if ( m ) o += ",";
        o += cell_json( c.original_contents[ m ] );
      }
      o += "]]";
    }
    o += "]}";
  }
  o += "]}";
  return o;
}

static std::vector<std::string> split( const std::string &line )
{
  std::vector<std::string> out;
  size_t start = 0;
  for ( ;; ) {
    size_t sp = line.find( ' ', start );
    out.push_back( line.substr( start, sp == std::string::npos ? std::string::npos : sp - start ) );
    if ( sp == std::string::npos ) break;
    start = sp + 1;
  }
  return out;
}

int predict_main( void )
{
  Complete *server = NULL;
  Framebuffer *shown = NULL;
  PredictionEngine *engine = NULL;
  bool shown_changed = false;
  uint64_t dumps = 0;

  std::string line;
  while ( std::getline( std::cin, line ) ) {
    std::vector<std::string> t = split( line );
    const std::string &cmd = t[ 0 ];
    const size_t argc = t.size() - 1;

    if ( cmd == "new" ) {
      if ( argc != 2 ) fail( "usage: new W H" );
      int w = size_arg( t[ 1 ] ), h = size_arg( t[ 2 ] );
      delete server;
      delete shown;
      delete engine;
      server = new Complete( w, h );
      shown = new Framebuffer( w, h );                /* stc:245 */
      engine = new PredictionEngine();                /* toh:294-307 */
      shown_changed = true;
      printf( "{\"ok\":\"new\"}\n" );
      continue;
    }
    if ( !server ) fail( "first command must be new" );

    if ( cmd == "display" ) {
      if ( argc != 1 ) fail( "usage: display NAME" );
      /* sth:109-120 */
      if ( t[ 1 ] == "always" ) engine->set_display_preference( PredictionEngine::Always );
      else if ( t[ 1 ] == "never" ) engine->set_display_preference( PredictionEngine::Never );
      else if ( t[ 1 ] == "adaptive" ) engine->set_display_preference( PredictionEngine::Adaptive );
      else if ( t[ 1 ] == "experimental" ) engine->set_display_preference( PredictionEngine::Experimental );
      else fail( "unknown display preference" );
    } else if ( cmd == "overwrite" ) {
      if ( argc != 1 || ( t[ 1 ] != "0" && t[ 1 ] != "1" ) ) fail( "usage: overwrite 0|1" );
      engine->set_predict_overwrite( t[ 1 ] == "1" );
    } else if ( cmd == "time" ) {
      if ( argc != 1 ) fail( "usage: time MS" );
      oracle_now = unsigned_arg( t[ 1 ] );
    } else if ( cmd == "host" ) {
      if ( argc > 1 ) fail( "usage: host HEX" );
      server->act( unhex( argc ? t[ 1 ] : std::string() ) );
    } else if ( cmd == "hostresize" ) {
      if ( argc != 2 ) fail( "usage: hostresize W H" );
      server->act( Parser::Resize( size_t( size_arg( t[ 1 ] ) ), size_t( size_arg( t[ 2 ] ) ) ) );
    } else if ( cmd == "echoack" ) {
      if ( argc != 1 ) fail( "usage: echoack N" );
      server->echo_ack = unsigned_arg( t[ 1 ] );      /* completeterminal.h:58 */
    } else if ( cmd == "recv" ) {
      if ( argc != 2 ) fail( "usage: recv ACKED SI" );
      uint64_t si = unsigned_arg( t[ 2 ] );
      if ( si > 0xFFFFFFFFu ) fail( "send interval out of range" );
      /* stc:298-300 */
      engine->set_local_frame_acked( unsigned_arg( t[ 1 ] ) );
      engine->set_send_interval( (unsigned int) si );
      engine->set_local_frame_late_acked( server->get_echo_ack() );
    } else if ( cmd == "read" ) {
      if ( argc < 1 || argc > 2 ) fail( "usage: read SENT HEX" );
      std::string bytes = unhex( argc == 2 ? t[ 2 ] : std::string() );
      /* stc:322-334 */
      engine->set_local_frame_sent( unsigned_arg( t[ 1 ] ) );
      bool paste = bytes.size() > 100;
      if ( paste ) {
        engine->reset();
      }
      for ( size_t i = 0; i < bytes.size(); i++ ) {
        if ( !paste ) {
          engine->new_user_byte( bytes[ i ], *shown );
        }
      }
    } else if ( cmd == "frame" ) {
      if ( argc != 0 ) fail( "usage: frame" );
      /* stc:274-287 without notifications, title and display; OverlayManager::apply's
         order (toc:335-336) */
      Framebuffer f( server->get_fb() );
      engine->cull( f );
      engine->apply( f );
      *shown = f;
      shown_changed = true;
    } else if ( cmd == "reset" ) {
      if ( argc != 0 ) fail( "usage: reset" );
      engine->reset();                                /* stc:418 */
    } else if ( cmd == "dump" ) {
      if ( argc != 0 ) fail( "usage: dump" );
      dumps++;
      std::string s = "null";
      if ( shown_changed ) {
        Complete wrap( shown->ds.width, shown->ds.height );
        wrap.terminal.fb = *shown;
        s = oracle_state_line( dumps, wrap );
        shown_changed = false;
      }
      printf( "{\"dump\":%llu,\"engine\":%s,\"shown\":%s}\n", (unsigned long long) dumps,
              engine_json( *engine ).c_str(), s.c_str() );
      continue;
    } else {
      fail( "unknown command " + cmd );
    }
    printf( "{\"ok\":\"%s\"}\n", cmd.c_str() );
  }
  fflush( stdout );
  return 0;
}

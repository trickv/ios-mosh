/*
 * What main.cc shares with predict.cc. See main.cc for the definitions.
 */
#ifndef MOSH_ORACLE_H
#define MOSH_ORACLE_H

#include <stdint.h>
#include <string>

#include "completeterminal.h"
#include "parser.h"

/* FORMAT.md state line with every key (full_line of make_dump), numbered num. */
std::string oracle_state_line( uint64_t num, const Terminal::Complete &c );
/* FORMAT.md 5.3 pen object. */
std::string oracle_rend_object( const Terminal::Renditions &r );
/* The name of a parser state, as the "parser_state" key of a state line. */
const char *oracle_parser_state_name( const Parser::State *s );
/* Standard base64 with padding. */
std::string oracle_b64( const std::string &in );

/* The predict mode (predict.cc): command stream on stdin, one reply line per command. */
int predict_main( void );

#endif

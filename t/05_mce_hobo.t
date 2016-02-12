#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 19;
use MCE::Hobo;
use Time::HiRes qw( sleep );

{
   my ( $cnt, @procs, @list, %ret );

   ok( 1, "spawning asynchronously" );

   push @procs, MCE::Hobo->new( sub { sleep 2; MCE::Hobo->tid } ) for 1 .. 3;

   @list = MCE::Hobo->list_running;
   is ( scalar @list, 3, 'check list_running' );

   @list = MCE::Hobo->list_joinable;
   is ( scalar @list, 0, 'check list_joinable' );

   @list = MCE::Hobo->list;
   is ( scalar @list, 3, 'check list' );

   is ( MCE::Hobo->pending, 3, 'check pending' );

   $cnt = 0;

   for ( @list ) {
      ++$cnt;
      is ( $_->is_running, 1, 'check is_running process'.$cnt );
      is ( $_->is_joinable, '', 'check is_joinable process'.$cnt );
   }

   $cnt = 0;

   for ( @list ) {
      ++$cnt; $ret{ $_->join } = 1;
      is ( $_->error, undef, 'check error process'.$cnt );
   }

   is ( scalar keys %ret, 3, 'check unique tid value' );
}

{
   my ( $cnt, @procs );

   push @procs, MCE::Hobo->new( sub { sleep 5; $_[0] }, $_ ) for 1 .. 3;

   $procs[0]->exit();
   $procs[1]->exit();
   $procs[2]->kill('QUIT');

   $cnt = 0;

   for ( @procs ) {
      ++$cnt;
      is ( $_->join, undef, 'check exit process'.$cnt );
   }
}

is ( MCE::Hobo->finish(), undef, 'check finish' );


###############################################################################
## ----------------------------------------------------------------------------
## Minidb helper class.
##
###############################################################################

package MCE::Shared::Minidb;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.699_008';

use MCE::Shared::Base;
use MCE::Shared::Ordhash;
use MCE::Shared::Array;
use MCE::Shared::Hash;
use bytes;

use overload (
   q("")    => \&MCE::Shared::Base::_stringify_a,
   q(0+)    => \&MCE::Shared::Base::_numify,
   fallback => 1
);

sub new {
   # Parallel Hashes: [ HoH, HoA ]
   bless [
      MCE::Shared::Ordhash->new(),  # Hash of Hashes (HoH)
      MCE::Shared::Ordhash->new(),  # Hash of Arrays (HoA)
   ], shift;
}

###############################################################################
## ----------------------------------------------------------------------------
## Private methods.
##
###############################################################################

#  Query string:
#
#  Several methods receive query string as an argument. The string is
#  quoteless. Any quotes inside the string will be treated literally.
#
#  Search capability { =~ !~ eq ne lt le gt ge == != < <= > >= }
#
#  "key =~ /pattern/i :AND field =~ /pattern/i"
#  "key =~ /pattern/i :AND index =~ /pattern/i"
#  "key =~ /pattern/i :AND field eq foo bar"     # address eq foo bar
#  "index eq foo baz :OR key !~ /pattern/i"      # 9 eq foo baz
#
#     key   means to match against keys in the hash (H)oH or (H)oA
#     field means to match against HoH->{key}->{field}; e.g. address
#     index means to match against HoA->{key}->[index]; e.g. 9
#
#  Keys in hash may have spaces, but not field names Ho(H).
#  Do not mix :AND(s) and :OR(s) together.

# _hfind ( { getkeys => 1 }, "query string" )
# _hfind ( { getvals => 1 }, "query string" )
#
# _hfind ( "query string" ) # pairs

sub _hfind {
   my $self   = shift;
   my $params = ref($_[0]) eq 'HASH' ? shift : {};

   if ( @_ == 2 ) {
      my $key = shift;
      return () unless exists($self->[0][0]{ $key });
      $self->[0][0]{ $key }->_find($params, @_);
   }
   else {
      my $query = shift;
      $params->{'hfind'} = 1;

      MCE::Shared::Base::_find_hash(
         $self->[0][0], $params, $query, $self->[0]->keys()
      );
   }
}

# _lfind ( { getkeys => 1 }, "query string" )
# _lfind ( { getvals => 1 }, "query string" )
#
# _lfind ( "query string" ) # pairs

sub _lfind {
   my $self   = shift;
   my $params = ref($_[0]) eq 'HASH' ? shift : {};

   if ( @_ == 2 ) {
      my $key = shift;
      return () unless exists($self->[1][0]{ $key });
      $self->[1][0]{ $key }->_find($params, @_);
   }
   else {
      my $query = shift;
      $params->{'lfind'} = 1;

      MCE::Shared::Base::_find_hash(
         $self->[1][0], $params, $query, $self->[1]->keys()
      );
   }
}

# _new_hash () applies to HoH

sub _new_hash {
   MCE::Shared::Hash->new();
}

# _new_list () applies to HoA

sub _new_list {
   MCE::Shared::Array->new();
}

# The hget_aref, hget_href, lget_aref, and lget_href methods receive an
# enhanced query string allowing one to specify field names and sorting
# directives. The shorter form is supported as well.
#
# "f1 f2 f3 :WHERE f4 > 20 :AND key =~ /foo/ :ORDER BY f5 DESC ALPHA"
# "f5 f1 f2 :WHERE fN > 40 :AND key =~ /bar/ :ORDER BY key ALPHA"
#
# "f1 f2 f3 :where f4 > 20 :and key =~ /foo/ :order by f5 desc alpha"
# "f5 f1 f2 :where fN > 40 :and key =~ /bar/ :order by key alpha"
#
# "f4 > 20 :and key =~ /baz/"

# _qparse ( "enhanced query string" )

sub _qparse {
   my ( $q ) = @_;
   my ( $f, $w, $o );

   if ( $q =~ /^([\S ]*):where[ ]+(.+):order by[ ]+(.+)/i ) {
      ( $f, $w, $o ) = ( $1, $2, $3 );
   }
   elsif ( $q =~ /^([\S ]*):where[ ]+(.+)/i ) {
      ( $f, $w ) = ( $1, $2 );
   }
   elsif ( $q =~ /^([\S ]*):order by[ ]+(.+)/i ) {
      ( $f, $o ) = ( $1, $2 );
   }
   elsif ( $q =~ /^((?:key|\S+)[ ]+(?:=|!|<|>|e|n|l|g)\S?[ ]+\S.*)/ ) {
      ( $w ) = ( $1 );
   }
   elsif ( $q =~ /^([\S ]*)/ ) {
      ( $f ) = ( $1 );
   }

   $f =~ s/[ ]+$//, $w =~ s/[ ]+$//, $o =~ s/[ ]+$//;

   return ( $f, $w, $o );
}

# _sort ( HoH, 0, "BY key   [ ASC | DESC ] [ ALPHA ]" )
# _sort ( HoH, 0, "BY field [ ASC | DESC ] [ ALPHA ]" ) e.g. BY address
# _sort ( HoA, 1, "BY key   [ ASC | DESC ] [ ALPHA ]" )
# _sort ( HoA, 1, "BY index [ ASC | DESC ] [ ALPHA ]" ) e.g. BY 9

sub _sort {
   my ( $o, $is_list, $request ) = @_;

   return () unless length($request);
   $request =~ s/^[ ]*\bby\b[ ]*//i;

   if ( $request =~ /^[ ]*(\S+)[ ]*(.*)/ ) {
      my ( $f, $modifiers, $alpha, $desc ) = ( $1, $2, 0, 0 );

      $alpha = 1 if $modifiers =~ /\balpha\b/i;
      $desc  = 1 if $modifiers =~ /\bdesc\b/i;

      # Return sorted keys
      if ( defined wantarray ) {
         if ( $f eq 'key' ) {                         # by key
            if ( $alpha ) { ( $desc )
             ? sort { $b cmp $a } $o->keys
             : sort { $a cmp $b } $o->keys;
            }
            else { ( $desc )
             ? sort { $b <=> $a } $o->keys
             : sort { $a <=> $b } $o->keys;
            }
         }
         else {                                       # by field
            my $d = $o->[0];
            if ( $is_list ) {
               if ( $alpha ) { ( $desc )
                ? sort { $d->{$b}[$f] cmp $d->{$a}[$f] } $o->keys
                : sort { $d->{$a}[$f] cmp $d->{$b}[$f] } $o->keys;
               }
               else { ( $desc )
                ? sort { $d->{$b}[$f] <=> $d->{$a}[$f] } $o->keys
                : sort { $d->{$a}[$f] <=> $d->{$b}[$f] } $o->keys;
               }
            }
            else {
               if ( $alpha ) { ( $desc )
                ? sort { $d->{$b}{$f} cmp $d->{$a}{$f} } $o->keys
                : sort { $d->{$a}{$f} cmp $d->{$b}{$f} } $o->keys;
               }
               else { ( $desc )
                ? sort { $d->{$b}{$f} <=> $d->{$a}{$f} } $o->keys
                : sort { $d->{$a}{$f} <=> $d->{$b}{$f} } $o->keys;
               }
            }
         }
      }

      # Sort in-place
      elsif ( $f eq 'key' ) {                         # by key
         if ( $alpha ) { ( $desc )
          ? $o->_reorder( sort { $b cmp $a } $o->keys )
          : $o->_reorder( sort { $a cmp $b } $o->keys );
         }
         else { ( $desc )
          ? $o->_reorder( sort { $b <=> $a } $o->keys )
          : $o->_reorder( sort { $a <=> $b } $o->keys );
         }
      }

      # Sort in-place
      else {                                          # by field
         my $d = $o->[0];
         if ( $is_list ) {
            if ( $alpha ) { ( $desc )
             ? $o->_reorder( sort { $d->{$b}[$f] cmp $d->{$a}[$f] } $o->keys )
             : $o->_reorder( sort { $d->{$a}[$f] cmp $d->{$b}[$f] } $o->keys );
            }
            else { ( $desc )
             ? $o->_reorder( sort { $d->{$b}[$f] <=> $d->{$a}[$f] } $o->keys )
             : $o->_reorder( sort { $d->{$a}[$f] <=> $d->{$b}[$f] } $o->keys );
            }
         }
         else {
            if ( $alpha ) { ( $desc )
             ? $o->_reorder( sort { $d->{$b}{$f} cmp $d->{$a}{$f} } $o->keys )
             : $o->_reorder( sort { $d->{$a}{$f} cmp $d->{$b}{$f} } $o->keys );
            }
            else { ( $desc )
             ? $o->_reorder( sort { $d->{$b}{$f} <=> $d->{$a}{$f} } $o->keys )
             : $o->_reorder( sort { $d->{$a}{$f} <=> $d->{$b}{$f} } $o->keys );
            }
         }
      }
   }
   else {
      ();
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## Hash of Hashes (HoH).
##
###############################################################################

# hset ( key, field, value [, field, value, ... ] )

sub hset {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key);
   if ( @_ ) {
      $self->[0]->set($key, _new_hash()) unless exists($self->[0][0]{ $key });
      @_ == 2
         ? $self->[0][0]{ $key }->set(@_)
         : $self->[0][0]{ $key }->mset(@_);
   }
   else {
      return;
   }
}

# hget ( key, field [, field, ... ] )
# hget ( key )

sub hget {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key);
   if ( @_ ) {
      return unless exists($self->[0][0]{ $key });
      @_ == 1
         ? $self->[0][0]{ $key }->get(@_)
         : $self->[0][0]{ $key }->mget(@_);
   }
   else {
      $self->[0][0]{ $key };
   }
}

# hdel ( key, field [, field, ... ] )
# hdel ( key )

sub hdel {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key);
   if ( @_ ) {
      return unless exists($self->[0][0]{ $key });
      @_ == 1
         ? $self->[0][0]{ $key }->del(@_)
         : $self->[0][0]{ $key }->mdel(@_);
   }
   else {
      $self->[0]->del($key);
   }
}

# hexists ( key, field [, field, ... ] )
# hexists ( key )

sub hexists {
   my ( $self, $key ) = ( shift, shift );
   return '' unless length($key);
   if ( @_ ) {
      return '' unless exists($self->[0][0]{ $key });
      @_ == 1
         ? $self->[0][0]{ $key }->exists(@_)
         : $self->[0][0]{ $key }->mexists(@_);
   }
   else {
      exists $self->[0][0]{ $key };
   }
}

# hclear ( key )
# hclear

sub hclear {
   my ( $self, $key ) = @_;
   if ( @_ > 1 ) {
      return unless exists($self->[0][0]{ $key });
      $self->[0][0]{ $key }->clear();
   }
   else {
      $self->[0]->clear();
   }
}

# hkeys ( key, field [, field, ... ] )
# hkeys ( "query string" )
# hkeys

sub hkeys {
   my $self = shift;

   if ( @_ == 1 && $_[0] =~ /^(?:key|\S+)[ ]+\S\S?[ ]+\S/ ) {
      $self->_hfind({ getkeys => 1 }, @_);
   }
   elsif ( @_ ) {
      my $key = shift;
      return () unless exists($self->[0][0]{ $key });
      $self->[0][0]{ $key }->keys(@_);
   }
   else {
      $self->[0]->keys();
   }
}

# hvals ( key, field [, field, ... ] )
# hvals ( "query string" )
# hvals

sub hvals {
   my $self = shift;

   if ( @_ == 1 && $_[0] =~ /^(?:key|\S+)[ ]+\S\S?[ ]+\S/ ) {
      $self->_hfind({ getvals => 1 }, @_);
   }
   elsif ( @_ ) {
      my $key = shift;
      return () unless exists($self->[0][0]{ $key });
      $self->[0][0]{ $key }->vals(@_);
   }
   else {
      $self->[0]->vals();
   }
}

# hpairs ( key, field [, field, ... ] )
# hpairs ( "query string" )
# hpairs

sub hpairs {
   my $self = shift;

   if ( @_ == 1 && $_[0] =~ /^(?:key|\S+)[ ]+\S\S?[ ]+\S/ ) {
      $self->_hfind({}, @_);
   }
   elsif ( @_ ) {
      my $key = shift;
      return () unless exists($self->[0][0]{ $key });
      $self->[0][0]{ $key }->pairs(@_);
   }
   else {
      $self->[0]->pairs();
   }
}

# hsort ( "BY key   [ ASC | DESC ] [ ALPHA ]" )
# hsort ( "BY field [ ASC | DESC ] [ ALPHA ]" )

sub hsort {
   my ( $self, $request ) = @_;
   return () unless ( @_ == 2 );
   _sort($self->[0], 0, $request);
}

# happend ( key, field, string )

sub happend {
   my ( $self, $key, $field ) = @_;
   return unless length($key) && length($field);
   $self->[0]->set($key, _new_hash()) unless exists($self->[0][0]{ $key });
   $self->[0][0]{ $key }->append($field, $_[3]);
}

# hdecr ( key, field )

sub hdecr {
   my ( $self, $key, $field ) = @_;
   return unless length($key) && length($field);
   $self->[0]->set($key, _new_hash()) unless exists($self->[0][0]{ $key });
   $self->[0][0]{ $key }->decr($field);
}

# hdecrby ( key, field, number )

sub hdecrby {
   my ( $self, $key, $field ) = @_;
   return unless length($key) && length($field);
   $self->[0]->set($key, _new_hash()) unless exists($self->[0][0]{ $key });
   $self->[0][0]{ $key }->decrby($field, $_[3]);
}

# hincr ( key, field )

sub hincr {
   my ( $self, $key, $field ) = @_;
   return unless length($key) && length($field);
   $self->[0]->set($key, _new_hash()) unless exists($self->[0][0]{ $key });
   $self->[0][0]{ $key }->incr($field);
}

# hincrby ( key, field, number )

sub hincrby {
   my ( $self, $key, $field ) = @_;
   return unless length($key) && length($field);
   $self->[0]->set($key, _new_hash()) unless exists($self->[0][0]{ $key });
   $self->[0][0]{ $key }->incrby($field, $_[3]);
}

# hgetdecr ( key, field )

sub hgetdecr {
   my ( $self, $key, $field ) = @_;
   return unless length($key) && length($field);
   $self->[0]->set($key, _new_hash()) unless exists($self->[0][0]{ $key });
   $self->[0][0]{ $key }->getdecr($field);
}

# hgetincr ( key, field )

sub hgetincr {
   my ( $self, $key, $field ) = @_;
   return unless length($key) && length($field);
   $self->[0]->set($key, _new_hash()) unless exists($self->[0][0]{ $key });
   $self->[0][0]{ $key }->getincr($field);
}

# hgetset ( key, field, value )

sub hgetset {
   my ( $self, $key, $field ) = @_;
   return unless length($key) && length($field);
   $self->[0]->set($key, _new_hash()) unless exists($self->[0][0]{ $key });
   $self->[0][0]{ $key }->getset($field, $_[3]);
}

# hlen ( key, field )
# hlen ( key )
# hlen

sub hlen {
   my $self = shift;
   if ( @_ ) {
      my $key = shift;
      return 0 unless exists($self->[0][0]{ $key });
      $self->[0][0]{ $key }->len(@_);
   }
   else {
      $self->[0]->len();
   }
}

# hget_aref ( "enhanced query string" ) see _qparse
# array containing [ key, aref ] pairs

sub hget_aref {
   my ( $self, $query ) = @_;
   my ( $f, $w, $o ) = _qparse($query);

   my @fields = split(' ', $f);
   my $data   = $self->[0][0];

   unless ( @fields ) {
      warn("hget_aref: must specify fieldname(s)");
      return ();
   }

   if ( length $w ) {
      my %match = map { $_ => 1 } ( $self->hkeys($w) );
      map { !exists $match{$_} ? () : do {
               my ( $k, @ret ) = ( $_ );
               push @ret, $data->{$k}{$_} for @fields;
               [ $k, \@ret ];
            };
          } ( length $o ? $self->hsort($o) : $self->hkeys() );
   }
   else {
      map { my ( $k, @ret ) = ( $_ );
            push @ret, $data->{$k}{$_} for @fields;
            [ $k, \@ret ];
          } ( length $o ? $self->hsort($o) : $self->hkeys() );
   }
}

# hget_href ( "enhanced query string" ) see _qparse
# array containing [ key, href ] pairs

sub hget_href {
   my ( $self, $query ) = @_;
   my ( $f, $w, $o ) = _qparse($query);

   my @fields = split(' ', $f);
   my $data   = $self->[0][0];

   if ( length $w ) {
      my %match = map { $_ => 1 } ( $self->hkeys($w) );
      if ( @fields ) {
         map { !exists $match{$_} ? () : do {
                  my ( $k, %ret ) = ( $_ );
                  $ret{$_} = $data->{$k}{$_} for @fields;
                  [ $k, \%ret ];
               };
             } ( length $o ? $self->hsort($o) : $self->hkeys() );
      }
      else {
         map { !exists $match{$_} ? () : [ $_, { %{ $data->{$_} } } ];
             } ( length $o ? $self->hsort($o) : $self->hkeys() );
      }
   }
   else {
      if ( @fields ) {
         map { my ( $k, %ret ) = ( $_ );
               $ret{$_} = $data->{$k}{$_} for @fields;
               [ $k, \%ret ];
             } ( length $o ? $self->hsort($o) : $self->hkeys() );
      }
      else {
         map { [ $_, { %{ $data->{$_} } } ];
             } ( length $o ? $self->hsort($o) : $self->hkeys() );
      }
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## Hash of Arrays (HoA).
##
###############################################################################

# lset ( key, index, value [, index, value, ... ] )

sub lset {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key);
   if ( @_ ) {
      $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
      @_ == 2
         ? $self->[1][0]{ $key }->set(@_)
         : $self->[1][0]{ $key }->mset(@_);
   }
   else {
      return;
   }
}

# lget ( key, index [, index, ... ] )
# lget ( key )

sub lget {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key);
   if ( @_ ) {
      return unless exists($self->[1][0]{ $key });
      @_ == 1
         ? $self->[1][0]{ $key }->get(@_)
         : $self->[1][0]{ $key }->mget(@_);
   }
   else {
      $self->[1][0]{ $key };
   }
}

# ldel ( key, index [, index, ... ] )
# ldel ( key )

sub ldel {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key);
   if ( @_ ) {
      return unless exists($self->[1][0]{ $key });
      @_ == 1
         ? $self->[1][0]{ $key }->del(@_)
         : $self->[1][0]{ $key }->mdel(@_);
   }
   else {
      $self->[1]->del($key);
   }
}

# lexists ( key, index [, index, ... ] )
# lexists ( key )

sub lexists {
   my ( $self, $key ) = ( shift, shift );
   return '' unless length($key);
   if ( @_ ) {
      return '' unless exists($self->[1][0]{ $key });
      @_ == 1
         ? $self->[1][0]{ $key }->exists(@_)
         : $self->[1][0]{ $key }->mexists(@_);
   }
   else {
      exists $self->[1][0]{ $key };
   }
}

# lclear ( key )
# lclear

sub lclear {
   my ( $self, $key ) = @_;
   if ( @_ > 1 ) {
      return unless exists($self->[1][0]{ $key });
      $self->[1][0]{ $key }->clear();
   }
   else {
      $self->[1]->clear();
   }
}

# lrange ( key, start, stop )

sub lrange {
   my ( $self, $key ) = ( shift, shift );
   return () unless length($key) && exists($self->[1][0]{ $key });
   $self->[1][0]{ $key }->range(@_);
}

# lsplice ( key, offset, length [, list ] )

sub lsplice {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key) && scalar(@_);
   $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
   $self->[1][0]{ $key }->splice(@_);
}

# lpop ( key )

sub lpop {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key) && exists($self->[1][0]{ $key });
   $self->[1][0]{ $key }->shift();
}

# lpush ( key, value [, value, ... ] )

sub lpush {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key) && scalar(@_);
   $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
   $self->[1][0]{ $key }->unshift(@_);
}

# rpop ( key )

sub rpop {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key) && exists($self->[1][0]{ $key });
   $self->[1][0]{ $key }->pop();
}

# rpush ( key, value [, value, ... ] )

sub rpush {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key) && scalar(@_);
   $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
   $self->[1][0]{ $key }->push(@_);
}

# lkeys ( key, index [, index, ... ] )
# lkeys ( "query string" )
# lkeys

sub lkeys {
   my $self = shift;

   if ( @_ == 1 && $_[0] =~ /^(?:key|\S+)[ ]+\S\S?[ ]+\S/ ) {
      $self->_lfind({ getkeys => 1 }, @_);
   }
   elsif ( @_ ) {
      my $key = shift;
      return () unless exists($self->[1][0]{ $key });
      $self->[1][0]{ $key }->keys(@_);
   }
   else {
      $self->[1]->keys();
   }
}

# lvals ( key, index [, index, ... ] )
# lvals ( "query string" )
# lvals

sub lvals {
   my $self = shift;

   if ( @_ == 1 && $_[0] =~ /^(?:key|\S+)[ ]+\S\S?[ ]+\S/ ) {
      $self->_lfind({ getvals => 1 }, @_);
   }
   elsif ( @_ ) {
      my $key = shift;
      return () unless exists($self->[1][0]{ $key });
      $self->[1][0]{ $key }->vals(@_);
   }
   else {
      $self->[1]->vals();
   }
}

# lpairs ( key, index [, index, ... ] )
# lpairs ( "query string" )
# lpairs

sub lpairs {
   my $self = shift;

   if ( @_ == 1 && $_[0] =~ /^(?:key|\S+)[ ]+\S\S?[ ]+\S/ ) {
      $self->_lfind({}, @_);
   }
   elsif ( @_ ) {
      my $key = shift;
      return () unless exists($self->[1][0]{ $key });
      $self->[1][0]{ $key }->pairs(@_);
   }
   else {
      $self->[1]->pairs();
   }
}

# lsort ( "BY key   [ ASC | DESC ] [ ALPHA ]" )
# lsort ( "BY index [ ASC | DESC ] [ ALPHA ]" )
#
# lsort ( key, "BY key [ ASC | DESC ] [ ALPHA ]" )
# lsort ( key, "BY val [ ASC | DESC ] [ ALPHA ]" )

sub lsort {
   my ( $self, $arg1, $arg2 ) = @_;
   if ( @_ == 2 ) {
      _sort($self->[1], 1, $arg1);
   }
   else {
      return () unless ( @_ == 3 && exists($self->[1][0]{ $arg1 }) );
      $self->[1][0]{ $arg1 }->sort($arg2);
   }
}

# lappend ( key, index, string )

sub lappend {
   my ( $self, $key, $field ) = @_;
   return unless length($key) && length($field);
   $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
   $self->[1][0]{ $key }->append($field, $_[3]);
}

# ldecr ( key, index )

sub ldecr {
   my ( $self, $key, $field ) = @_;
   return unless length($key) && length($field);
   $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
   $self->[1][0]{ $key }->decr($field);
}

# ldecrby ( key, index, number )

sub ldecrby {
   my ( $self, $key, $field ) = @_;
   return unless length($key) && length($field);
   $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
   $self->[1][0]{ $key }->decrby($field, $_[3]);
}

# lincr ( key, index )

sub lincr {
   my ( $self, $key, $field ) = @_;
   return unless length($key) && length($field);
   $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
   $self->[1][0]{ $key }->incr($field);
}

# lincrby ( key, index, number )

sub lincrby {
   my ( $self, $key, $field ) = @_;
   return unless length($key) && length($field);
   $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
   $self->[1][0]{ $key }->incrby($field, $_[3]);
}

# lgetdecr ( key, index )

sub lgetdecr {
   my ( $self, $key, $field ) = @_;
   return unless length($key) && length($field);
   $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
   $self->[1][0]{ $key }->getdecr($field);
}

# lgetincr ( key, index )

sub lgetincr {
   my ( $self, $key, $field ) = @_;
   return unless length($key) && length($field);
   $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
   $self->[1][0]{ $key }->getincr($field);
}

# lgetset ( key, index, value )

sub lgetset {
   my ( $self, $key, $field ) = @_;
   return unless length($key) && length($field);
   $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
   $self->[1][0]{ $key }->getset($field, $_[3]);
}

# llen ( key, index )
# llen ( key )
# llen

sub llen {
   my $self = shift;
   if ( @_ ) {
      my $key = shift;
      return 0 unless exists($self->[1][0]{ $key });
      $self->[1][0]{ $key }->len(@_);
   }
   else {
      $self->[1]->len();
   }
}

# lget_aref ( "enhanced query string" ) see _qparse
# array containing [ key, aref ] pairs

sub lget_aref {
   my ( $self, $query ) = @_;
   my ( $f, $w, $o ) = _qparse($query);

   my @fields = split(' ', $f);
   my $data   = $self->[1][0];

   if ( length $w ) {
      my %match = map { $_ => 1 } ( $self->lkeys($w) );
      if ( @fields ) {
         map { !exists $match{$_} ? () : do {
                  my ( $k, @ret ) = ( $_ );
                  push @ret, $data->{$k}[$_] for @fields;
                  [ $k, \@ret ];
               };
             } ( length $o ? $self->lsort($o) : $self->lkeys() );
      }
      else {
         map { !exists $match{$_} ? () : [ $_, [ @{ $data->{$_} } ] ];
             } ( length $o ? $self->lsort($o) : $self->lkeys() );
      }
   }
   else {
      if ( @fields ) {
         map { my ( $k, @ret ) = ( $_ );
               push @ret, $data->{$k}[$_] for @fields;
               [ $k, \@ret ];
             } ( length $o ? $self->lsort($o) : $self->lkeys() );
      }
      else {
         map { [ $_, [ @{ $data->{$_} } ] ];
             } ( length $o ? $self->lsort($o) : $self->lkeys() );
      }
   }
}

# lget_href ( "enhanced query string" ) see _qparse
# array containing [ key, href ] pairs

sub lget_href {
   my ( $self, $query ) = @_;
   my ( $f, $w, $o ) = _qparse($query);

   my @fields = split(' ', $f);
   my $data = $self->[1][0];

   if ( length $w ) {
      my %match = map { $_ => 1 } ( $self->lkeys($w) );
      if ( @fields ) {
         map { !exists $match{$_} ? () : do {
                  my ( $k, %ret ) = ( $_ );
                  $ret{$_} = $data->{$k}[$_] foreach @fields;
                  [ $k, \%ret ];
               };
             } ( length $o ? $self->lsort($o) : $self->lkeys() );
      }
      else {
         map { !exists $match{$_} ? () : do {
                  my ( $k, %ret ) = ( $_ );
                  $ret{$_} = $data->{$k}[$_] for 0 .. $#{ $data->{$k} };
                  [ $k, \%ret ];
               };
             } ( length $o ? $self->lsort($o) : $self->lkeys() );
      }
   }
   else {
      if ( @fields ) {
         map { my ( $k, %ret ) = ( $_ );
               $ret{$_} = $data->{$k}[$_] foreach @fields;
               [ $k, \%ret ];
             } ( length $o ? $self->lsort($o) : $self->lkeys() );
      }
      else {
         map { my ( $k, %ret ) = ( $_ );
               $ret{$_} = $data->{$k}[$_] for 0 .. $#{ $data->{$k} };
               [ $k, \%ret ];
             } ( length $o ? $self->lsort($o) : $self->lkeys() );
      }
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## Common methods.
##
###############################################################################

# iterator ( ":lists" )
# iterator ( ":lists", "query string" )
# iterator ( ":lists", key, "query string" )
# iterator ( ":lists", key [, key, ... ] )
#
# iterator ( ":hashes" )
# iterator ( ":hashes", "query string" )
# iterator ( ":hashes", key, "query string" )
# iterator ( ":hashes", key [, key, ... ] )
#
# iterator  same as ":hashes"

sub iterator {
   my ( $self, @keys ) = @_;
   my $data;

   if ( $keys[0] =~ /^:lists$/i ) {
      $data = $self->[1][0];
      shift @keys;
      if ( !scalar @keys ) {
         @keys = $self->lkeys();
      }
      elsif ( @keys == 1 && $keys[0] =~ /^(?:key|\S+)[ ]+\S\S?[ ]+\S/ ) {
         @keys = $self->lkeys(@keys);
      }
      elsif ( @keys == 2 && $keys[1] =~ /^(?:key|val)[ ]+\S\S?[ ]+\S/ ) {
         $data = $self->[1][0]->{ $keys[0] };
         @keys = $self->lkeys(@keys);
         return sub {
            return unless @keys;
            my $key = shift(@keys);
            return ( $key => $data->[ $key ] );
         };
      }
   }
   else {
      $data = $self->[0][0];
      shift @keys if ( $keys[0] =~ /^:hashes$/i );
      if ( !scalar @keys ) {
         @keys = $self->hkeys();
      }
      elsif ( @keys == 1 && $keys[0] =~ /^(?:key|\S+)[ ]+\S\S?[ ]+\S/ ) {
         @keys = $self->hkeys(@keys);
      }
      elsif ( @keys == 2 && $keys[1] =~ /^(?:key|val)[ ]+\S\S?[ ]+\S/ ) {
         $data = $self->[0][0]->{ $keys[0] };
         @keys = $self->hkeys(@keys);
      }
   }

   return sub {
      return unless @keys;
      my $key = shift(@keys);
      return ( $key => $data->{ $key } );
   };
}

# dump ( "file.dat" )

sub dump {
   my ( $self, $file ) = @_;

   if ( length $file ) {
      require Storable unless $INC{'Storable.pm'};

      # purge tombstones
      $self->[0]->purge(), $self->[1]->purge();

      local ( $SIG{__DIE__}, $@ ) = ( sub { } );
      eval { Storable::nstore($self, $file) };

      warn($@), return if $@;
   }
   else {
      warn('Usage: $obj->dump("file.dat")');
      return;
   }

   1;
}

# restore ( "file.dat" )

sub restore {
   my ( $self, $file ) = @_;

   if ( length $file ) {
      require Storable unless $INC{'Storable.pm'};

      local ( $SIG{__DIE__}, $@ ) = ( sub { } );
      my $obj = eval { Storable::retrieve($file) };
      warn($@), return if $@;

      if ( ref($obj) ne 'MCE::Shared::Minidb' ) {
         warn("$file isn't serialized Minidb data: ".ref($obj));
         return;
      }
      $self->[1]->clear(), $self->[1] = delete $obj->[1];
      $self->[0]->clear(), $self->[0] = delete $obj->[0];
   }
   else {
      warn('Usage: $obj->restore("file.dat")');
      return;
   }

   1;
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Shared::Minidb - Minidb helper class

=head1 VERSION

This document describes MCE::Shared::Minidb version 1.699_008

=head1 SYNOPSIS

   # non-shared
   use MCE::Shared::Minidb;

   my $db = MCE::Shared::Minidb->new();

   # shared
   use MCE::Shared;

   my $db = MCE::Shared->minidb();

   TODO, more more info :)

      It has taken a long time, but all of this is coming together.
      MCE::Shared::Server is fully completed and quite fast.
      I'm going through and completing the documentation.
      The ETA for MCE 1.7 is Feb 2016.


=head1 DESCRIPTION

A simplistic In-Memory NoSQL DB for use with L<MCE::Shared|MCE::Shared>.

=head1 NOTE on QUERY STRING

Several methods in C<MCE::Shared::Minidb> receive query string as an argument.
The string is quoteless. Any quotes inside the string will be treated literally.

   Search capability { =~ !~ eq ne lt le gt ge == != < <= > >= }
  
   "key =~ /pattern/i :AND field =~ /pattern/i"
   "key =~ /pattern/i :AND index =~ /pattern/i"
   "key =~ /pattern/i :AND field eq foo bar"     # address eq foo bar
   "index eq foo baz :OR key !~ /pattern/i"      # 9 eq foo baz

      key   means to match against keys in the hash (H)oH or (H)oA
      field means to match against HoH->{key}->{field}; e.g. address
      index means to match against HoA->{key}->[index]; e.g. 9

   Keys in hash may have spaces, but not field names Ho(H).
   Do not mix :AND(s) and :OR(s) together.

The C<hget_aref>, C<hget_href>, C<lget_aref>, and C<lget_href> methods receive
an enhanced query string allowing one to specify field names and sorting
directives. The shorter form is supported as well.

   "f1 f2 f3 :WHERE f4 > 20 :AND key =~ /foo/ :ORDER BY f5 DESC ALPHA"
   "f5 f1 f2 :WHERE fN > 40 :AND key =~ /bar/ :ORDER BY key ALPHA"

   "f1 f2 f3 :where f4 > 20 :and key =~ /foo/ :order by f5 desc alpha"
   "f5 f1 f2 :where fN > 40 :and key =~ /bar/ :order by key alpha"

   "f4 > 20 :and key =~ /baz/"
  
=head1 API DOCUMENTATION - HASHES HoH

=over 3

=item hset ( key, field, value [, field, value, ... ] )

=item hget ( key, field [, field, ... ] )

=item hget ( key )

=item hdel ( key, field [, field, ... ] )

=item hdel ( key )

=item hexists ( key, field [, field, ... ] )

=item hexists ( key )

=item hclear ( key )

=item hclear

=item hkeys ( key, field [, field, ... ] )

=item hkeys ( "query string" )

=item hkeys

=item hvals ( key, field [, field, ... ] )

=item hvals ( "query string" )

=item hvals

=item hpairs ( key, field [, field, ... ] )

=item hpairs ( "query string" )

=item hpairs

=item hsort ( "BY key [ ASC | DESC ] [ ALPHA ]" )

=item hsort ( "BY field [ ASC | DESC ] [ ALPHA ]" )

=item happend ( key, field, string )

=item hdecr ( key, field )

=item hdecrby ( key, field, number )

=item hincr ( key, field )

=item hincrby ( key, field, number )

=item hgetdecr ( key, field )

=item hgetincr ( key, field )

=item hgetset ( key, field, value )

=item hlen ( key, field )

=item hlen ( key )

=item hlen

=item hget_aref ( "enhanced query string" )

   returns [ key, aref ] pairs

=item hget_href ( "enhanced query string" )

   returns [ key, href ] pairs

=back

=head1 API DOCUMENTATION - LISTS HoA

=over 3

=item lset ( key, index, value [, index, value, ... ] )

=item lget ( key, index [, index, ... ] )

=item lget ( key )

=item ldel ( key, index [, index, ... ] )

=item ldel ( key )

=item lexists ( key, index [, index, ... ] )

=item lexists ( key )

=item lclear ( key )

=item lclear

=item lrange ( key, start, stop )

=item lsplice ( key, offset, length [, list ] )

=item lpop ( key )

=item lpush ( key, value [, value, ... ] )

=item rpop ( key )

=item rpush ( key, value [, value, ... ] )

=item lkeys ( key, index [, index, ... ] )

=item lkeys ( "query string" )

=item lkeys

=item lvals ( key, index [, index, ... ] )

=item lvals ( "query string" )

=item lvals

=item lpairs ( key, index [, index, ... ] )

=item lpairs ( "query string" )

=item lpairs

=item lsort ( "BY key [ ASC | DESC ] [ ALPHA ]" )

=item lsort ( "BY index [ ASC | DESC ] [ ALPHA ]" )

=item lsort ( key, "BY key [ ASC | DESC ] [ ALPHA ]" )

=item lsort ( key, "BY val [ ASC | DESC ] [ ALPHA ]" )

=item lappend ( key, index, string )

=item ldecr ( key, index )

=item ldecrby ( key, index, number )

=item lincr ( key, index )

=item lincrby ( key, index, number )

=item lgetdecr ( key, index )

=item lgetincr ( key, index )

=item lgetset ( key, index, value )

=item llen ( key, index )

=item llen ( key )

=item llen

=item lget_aref ( "enhanced query string" )

This returns [ key, aref ] pairs.

=item lget_href ( "enhanced query string" )

This returns [ key, href ] pairs.

=back

=head1 COMMON API

=over 3

=item iterator ( ":hashes" )

=item iterator ( ":hashes", "query string" )

=item iterator ( ":hashes", key, "query string" )

=item iterator ( ":hashes", key [, key, ... ] )

=item iterator

Returns a code reference that returns a single key => href/value pair.

=item iterator ( ":lists" )

=item iterator ( ":lists", "query string" )

=item iterator ( ":lists", key, "query string" )

=item iterator ( ":lists", key [, key, ... ] )

Returns a code reference that returns a single key => aref/value pair.

=item dump ( "file.dat" )

Dump the contents to a file.

=item restore ( "file.dat" )

Restore contents from a file.

=back

=head1 CREDITS

The implementation is inspired by various Redis Hash/List primitives at
L<http://redis.io/commands>.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core|MCE::Core>, L<MCE::Shared|MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

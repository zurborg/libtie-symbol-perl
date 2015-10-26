use strict;
use warnings 'all';

package Tie::Symbol;

# ABSTRACT: Tied interface to the symbol table

use Carp qw(croak);
use base 'Tie::Hash';
no strict 'refs'; ## no critic

# VERSION

=head1 SYNOPSIS

    sub abc { 123 };

    my $ST = Tie::Symbol->new;
    my $abc = $ST->{'&abc'};
    $abc->(); # returns 123

    $ST->{'&abc'} = sub { 456 };
    abc(); # returns 456

    tie(my %ST, 'Tie::Symbol');
    $ST{'&abc'}; # see above

=cut

my %sigils = (
  SCALAR => '$',
  ARRAY => '@',
  HASH => '%',
  CODE => '&',
  GLOB => '*',
  '$' => 'SCALAR',
  '@' => 'ARRAY',
  '%' => 'HASH',
  '&' => 'CODE',
  '*' => 'GLOB',
);

sub _globtype {
  my $glob = shift;
  my %R;
  foreach my $type (qw(ARRAY HASH CODE SCALAR)) {
    my $ref = *{$glob}{$type};
    return $ref if $ref;
  }
}

=head1 DESCRIPTION

The tied hash represents the internal symbol table which allows the user to examine and modify the whole symbol table.

Currently this implementation limits the referents to scalars, arrays, hashes and subroutines.

=cut

use namespace::clean;

=head2 Tied hash

    tie my %hash, 'Tie::Symbol', $package;

The hash is tied to a specific namespace or the main package if no package is given.

=cut

sub TIEHASH {
    my ($class, $namespace) = @_;

    $namespace //= 'main';

    my $classname = ref $class || $class;

    my $self = {
        ns => "$namespace",
    };

    bless $self => $classname;
}

=head2 Examine

    our $PKG::scalar = 123;
    tie my %ST, 'Tie::Symbol', 'PKG';
    my $ScalarRef = $ST{'$scalar'};

    package X::Y {
        sub z { ... }
    }

    my $ST = Tie::Symbol->new;
    my $z = $ST->{X}->{Y}->{'&z'};
    my $z = $ST->{'X::Y'}->{'&z'};
    my $z = $ST->{'&X::Y::z'};

=cut

sub FETCH {
    my ($self, $name, $force) = @_;
    return $self->{$name} if (not $force and scalar caller eq __PACKAGE__);
    my $namespace = $self->namespace;
    if (my ($sigil, $label) = ($name =~ m{^([\$\@\%\&])(.+)$})) {
        my $type = $sigils{$sigil};
        my $symbol = *{"${namespace}::${label}"} // return;
        my $referent = *{$symbol}{$type} // return;
        return $referent;
    } else {
        return if $namespace eq 'main' and $name eq 'main';
        return $self->new("${namespace}::${name}");
    }
}

=head1 Dumping

    tie my %ST, 'Tie::Symbol', 'PKG';
    my @symbols = keys %ST;

=cut

sub FIRSTKEY {
    my $self = shift;
    my $notnextkey = shift;
    my $namespace = $self->namespace;
    my $base = *{"${namespace}::"};
    my @symbols;
    foreach my $key (keys %$base) {
        if ($key =~ m{^(.+)::$}) {
            push @symbols => $1;
        } else {
            my $symbol = *{"${namespace}::${key}"};
            my $ref = _globtype($symbol) // croak "not a valid symbol: $symbol";
            next unless exists $sigils{ref($ref)};
            my $name = $sigils{ref($ref)}.$key;
            push @symbols => $name;
        }
    }
    $self->{symbols} = [ sort @symbols ];
    $self->NEXTKEY unless $notnextkey;
}

sub NEXTKEY {
    my $self = shift;
    shift @{ $self->{symbols} };
}

=head2 Existence

    exists $ST{'&code'} ? 'code exists' : 'code dont exists'

B<Caveat:> existence checks on scalars and namespaces always returns true.

=cut

sub EXISTS {
    my ($self, $key) = @_;
    defined $self->FETCH($key, 1);
}

=head2 Modify

    $ST{'&code'} = sub { ... };
    $ST{'$scalar'} = \"...";
    $ST{'@array'} = [ ... ];
    $ST{'%hash'} = { ... };

=cut

sub STORE {
    my $self = shift;
    my $name = shift;
    return ($self->{$name} = shift) if (scalar caller eq __PACKAGE__);
    my $namespace = $self->namespace;
    if (my ($sigil, $label) = ($name =~ m{^([\$\@\%\&])(.+)$})) {
        my $ref = shift;
        unless (ref $ref) {
            croak "cannot assign unreferenced thing to $sigil$label";
        }
        my $type = $sigils{$sigil};
        if ($type ne ref $ref) {
            croak "cannot assign $ref to $type (${sigil}${namespace}::${label})";
        }
        #undef *{"${namespace}::${label}"};
        no warnings 'redefine';
        *{"${namespace}::${label}"} = $ref;
    } else {
        croak "$name is not a valid identifier";
    }
}

=head2 Erasing

    sub PKG::abc { ... }
    tie my %ST, 'Tie::Symbol', 'PKG';
    PKG::abc(); # works
    my $abc = delete $ST{'&abc'};
    PKG::abc(); # croaks
    $abc->(); # subroutine survived anonymously!

=cut

sub DELETE {
    my $self = shift;
    my $name = shift;
    my $namespace = $self->namespace;
    if (my ($sigil, $label) = ($name =~ m{^([\$\@\%\&])(.+)$})) {
        my $type = $sigils{$sigil};
        my $referent = *{"${namespace}::${label}"}{$type} // return;
        undef *{"${namespace}::${label}"};
        return $referent;
    } else {
        $self->FETCH($name, 1)->CLEAR;
    }
}

=head2 Clearing

    tie my %ST, 'Tie::Symbol', 'PKG';
    %ST = ();

=cut

sub CLEAR {
    my $self = shift;
    $self->FIRSTKEY(1);
    while (my $key = $self->NEXTKEY) {
        $self->DELETE($key);
        #die "not deleted: $key" if $self->EXISTS($key);
    }
}

=method namespace

Returns the current namespace

    $ST->namespace;

Thats in short just whats given as package name to L</new>

=cut

sub namespace {
    shift->{ns}
}

sub _parts {
    split /::/ => shift->namespace
}

=method parent_namespace

Return the name of the parent namespace.

    my $parent_ns = $ST->parent_namespace;

Returns C<undef> if there is no parent namespace

=cut

sub parent_namespace {
    my $self = shift;
    my @parts = $self->_parts;
    my $class = join('::', @parts);
    return unless @parts > 1;
    return join('::', @parts[0..$#parts-1]);
}

=method parent

Like L</parent_namespace> but return an instance of L<Tie::Symbol>.

    my $parent = $ST->parent;
    my $parent_ns = $parent->namespace;

Returns C<undef> if there is no parent namespace

=cut

sub parent {
    my $self = shift;
    my $parent = $self->parent_namespace // return;
    return $self->new($parent);
}

=method search

Search for a symbol with a regular expression

    my @zzz = $ST->search(qr{zzz});

=cut

sub search {
    my $self = shift;
    my $re = shift;
    return grep { $_ =~ $re } keys %$self;
}

my $SS = quotemeta('$');
my $HS = quotemeta('%');
my $AS = quotemeta('@');
my $CS = quotemeta('&');

=method scalars

Returns a list of all scalars

    my @scalars = $ST->scalars;

=cut

sub scalars {
    shift->search(qr{^$SS});
}

=method hashes

Returns a list of all hashes

    my @hashes = $ST->hashes;

=cut

sub hashes {
    shift->search(qr{^$HS});
}

=method arrays

Returns a list of all arrays

    my @arrays = $ST->arrays;

=cut

sub arrays {
    shift->search(qr{^$AS});
}

=method subs

Returns a list of all subroutines

    my @subs = $ST->subs;

=cut

sub subs {
    shift->search(qr{^$CS});
}

=method classes

Returns a list of all subclasses in namespace

    my @classes = $ST->classes;

=cut

sub classes {
    shift->search(qr{^[^\$\@\%\&]});
}

=method tree

Returns a recursive HashRef with all subclasses of a namespace

    my $tree = $ST->tree;

=cut

sub tree {
    my $self = shift;
    my @classes = grep { exists $self->{$_} } $self->classes;
    return { map {( $_ => $self->FETCH($_, 1)->tree )} @classes };
}

=method new

Returns a blessed reference to a tied hash of ourselves.

    my $ST = Tie::Symbol->new;

=cut

sub new {
    my $class = shift;
    my $classname = ref $class || $class;
    tie(my %table, $classname,  @_);
    bless(\%table, $classname);
}

=method mine

Return the symbol table of the caller's scope.

    my $my_symbol_table = Tie::Symbol->mine;

=cut

sub mine {
    shift->new(scalar caller);
}

1;

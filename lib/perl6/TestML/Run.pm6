#------------------------------------------------------------------------------
class TestML::Block {
  has $.label;
  has $.point;
}

#------------------------------------------------------------------------------
class TestML::Run {

use JSON::Tiny;

has $!vtable = {
  '=='    => 'assert-eq',
  '~~'    => 'assert-has',
  '=~'    => 'assert-like',

  '.'     => 'exec-expr',
  '%()'   => 'pick-loop',
  '()'    => 'pick-exec',

  Q[$'']  => 'get-str',
  '*'     => 'get-point',
  '='     => 'set-var',
};

has $!types = {
  string => 'str',
  number => 'num',
  boolean => 'bool',
  testml => {
    '=>' => 'func',
    '/' => 'regex',
    '!' => 'error',
    '?' => 'native',
  },
  group => {
    Object => 'hash',
    Array => 'list',
  }
};

has TestML::Block $.block;

has Str $!file;
has Str $!version;
has Array $!code;
has Array $!data;

has $!bridge;
has $!stdlib;

has $!vars;

method new(:$file='', :$testml={}, :$bridge, :$stdlib) {
  my $self = self.bless:
    file => $file,
    bridge => $bridge,
    stdlib => $stdlib,
    vars => {};

  $!version = $testml<testml> if $testml<testml>;
  $!code = $testml<code> if $testml<code>;
  $!data = $testml<data> if $testml<data>;

  return $self;
}

method from-file($file) {
  $!file = $file;

  my $testml = from-json slurp $!file;
  ($!version, $!code, $!data) = $testml<testml code data>;

  return self;
}

method test {
  self.initialize;

  self.test-begin;

  self.exec-func([], $!code);

  self.test-end;

  return;
}

#------------------------------------------------------------------------------
method getp($name) {
  return unless $.block;
  return $.block.point{$name};
}

method getv($name) {
  return $!vars{$name};
}

method setv($name, $value) {
  $!vars{$name} = $value;
  return;
}

#------------------------------------------------------------------------------
method exec($expr) {
  self.exec_expr($expr)[0];
}

method exec_expr($expr, $context=[]) {
  return [$expr] if
    not $expr ~~ Array or
    $expr[0] ~~ Array or
    $expr[0] ~~ Str and $expr[0] ~~ /^[\=\>|\/|\?|\!]$/;

  my @args = @$expr.clone;
  my @return;
  my $name = @args.shift;
  my $opcode = $name;
  if my $call = $!vtable{$opcode} {
    @return = self."$call"(|@args);
  }
  else {
    @args = @args.map: {
      $_ ~~ Array ?? self.exec($_) !! $_;
    };

    @args.unshift($_) for $context.reverse;

    if $name ~~ /^<[a..z]>/ {
      my $call = $name;
      if not $!bridge {
        $!bridge = (require ::(%*ENV<TESTML_BRIDGE>)).new;
      }
      die "Can't find bridge function: '$name'"
        unless $!bridge.can($call);
      @return = $!bridge."$call"(|@args);
    }
    elsif ($name ~~ /^<[A..Z]>/) {
      @return = self.call_stdlib($name, @args);
    }
    else {
      die "Can't resolve TestML function '$name'";
    }
  }

  return @return;
}

method exec-func($context, @function) {
  my $signature = @function.shift;

  for @function -> $statement {
    self.exec_expr($statement);
  }

  return;
}

method exec-expr(*@args) {
  my $context = [];

  for |@args -> $call {
    $context = self.exec_expr($call, $context);
  }

  return |$context;
}

method pick-loop($list, $expr) {
  for |$!data -> $block {
    $!block = $block;

    self.exec_expr(['()', $list, $expr]);
  }

  $!block = Nil;

  return;
}

method pick-exec($list, $expr) {
  my $pick = True;
  for |$list -> $point {
    if ($point ~~ /^\*/ and
        not $.block.point{substr($point, 1)}:exists) or
       ($point ~~ /^\!\*/ and
        $.block.point{substr($point, 2)}:exists
    ) {
      $pick = False;
      last;
    }
  }

  if $pick {
    self.exec_expr($expr);
  }
}

method get-str($original) {
  my $string = $original;

  $string ~~ s/\{(<[\w\-]>+)\}/{$.vars{$0}}/;

  $string ~~ s:g/\{\*(<[\w\-]>+)\}/{$.block.point{$0}}/;

  return $string;
}

method get-point($name) {
  return self.getp($name);
}

method set-var($name, $expr) {
  self.setv($name, self.exec($expr));

  return;
}

method assert-eq($left, $right, $label-expr='') {
  my $got = self.exec($left);

  my $want = self.exec($right);

  my $label = self.get-label($label-expr);

  self.test-eq($got, $want, $label);

  return;
}

#------------------------------------------------------------------------------
method type ($value) {
  return Nil if $value ~~ Nil;

  return 'str' if $value ~~ Str;
  return 'num' if $value ~~ Int;
  return 'regex' if $value ~~ Array and
    $value.elems == 2 and
    $value[0] ~~ Str and
    $value[0] eq '/';

  die 43;
}

method cook($value) {
  #  return [] if not $value.defined;
  return Nil if not $value.defined;
  return $value if $value ~~ Str | Bool | Num | Int;
  return ['/', $value] if $value ~~ Regex;
  die 42;
}

method uncook($value) {
  my $type = self.type($value);
  if $type eq 'regex' {
    if $value[1] ~~ Str {
      return rx/$value[1]/;
    }
    return $value[1];
  }
  if $type ~~ 'str' | 'num' {
    return $value;
  }
  die 44;
}

method call_stdlib($name, @args) {
  require TestML::StdLib;
  $!stdlib ||= TestML::StdLib.new:
    run => self;

  my $call = $name.lc;
  die "Unknown TestML Standard Library function: '$name'"
    unless $!stdlib.can($call);

  @args = [
    @args.map: {
      self.uncook(self.exec($_));
    }
  ];

  self.cook($!stdlib."$call"(|@args));
}

method initialize {
  $!code.unshift([]);

  $!data = [
    $!data.map: {
      TestML::Block.new(|$_);
    }
  ];

  return;
}

method get-label($label-expr='') {
  my $label = self.exec($label-expr);

  if not $label {
    $label = self.getv('Label') || '';
    if $label ~~ /\{\*?<[\w\-]>\}/ {
      $label = self.exec(["\$''", $label]);
    }
  }

  my $block-label = $.block ?? $.block.label !! '';

  if $label {
    $label ~~ s/^\+/$block-label/;
    $label ~~ s/\+$/$block-label/;
    $label ~~ s/\{\+\}/$block-label/;
  }
  else {
    $label = $block-label;
  }

  return $label;
}

} # class TestML::Run

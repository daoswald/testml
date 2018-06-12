unit class TestML::StdLib;

has $.run;

method False {
  False;
}

method true {
  True;
}

method type ($value) {
  $!run.type($!run.cook($value));
}

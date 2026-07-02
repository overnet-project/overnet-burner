requires 'perl', '5.040';
requires 'strictures', '2';
requires 'JSON', 0;
requires 'Moo', 0;
requires 'Net::Nostr', 0;
requires 'Rex', 0;
requires 'YAML::PP', 0;

on 'test' => sub {
  requires 'JSON::Schema::Modern', 0;
};

requires 'parent', 0;
requires 'Future', '>= 0.29';
requires 'Carp', 0;
requires 'IO::Async', '>= 0.62';
requires 'Protocol::SOCKS', '>= 0.003';
requires 'Syntax::Keyword::Try', 0;

on 'test' => sub {
	requires 'Test::More', '>= 0.98';
	requires 'Test::Fatal', '>= 0.010';
	requires 'Test::Refcount', '>= 0.07';
};


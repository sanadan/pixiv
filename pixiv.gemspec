# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'pixiv/version'

Gem::Specification.new do |gem|
  gem.name          = "pixiv"
  gem.version       = Pixiv::VERSION
  gem.authors       = ["Tomoki Aonuma"]
  gem.email         = ["uasi@uasi.jp"]
  gem.description   = %q{A client library for Pixiv}
  gem.summary       = %q{A client library for Pixiv}
  gem.homepage      = "https://github.com/uasi/pixiv"

  gem.files         = `git ls-files`.split($/)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.require_paths = ["lib"]

  gem.add_dependency 'mechanize', '~> 2.0'
end
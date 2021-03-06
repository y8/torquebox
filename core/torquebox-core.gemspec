require "#{File.dirname(__FILE__)}/lib/torquebox/version"

Gem::Specification.new do |s|
  s.name     = 'torquebox-core'
  s.version  = TorqueBox::VERSION
  s.platform = 'java'
  s.summary  = 'TorqueBox Next Generation'
  s.author   = 'The TorqueBox Team'
  s.email    = 'torquebox-dev@torquebox.org'
  s.homepage = 'http://torquebox.org/4x'

  s.required_ruby_version = '>= 1.9.3'
  s.license = 'Apache-2.0'

  s.require_paths = ["lib"]
  s.bindir        = 'bin'
  s.executables   = ['torquebox']
  s.files         = Dir['CHANGELOG.md', 'README.md', 'LICENSE',
                        'bin/**/*', 'lib/**/*']

  s.add_development_dependency('jbundler')
  s.add_development_dependency('rake')
  s.add_development_dependency('rake-compiler')
  s.add_development_dependency('rspec', '~> 2.14')

  s.requirements << "jar org.projectodd.wunderboss:wunderboss-ruby, #{TorqueBox::WUNDERBOSS_VERSION}"
  s.requirements << "jar org.projectodd.wunderboss:wunderboss-wildfly, #{TorqueBox::WUNDERBOSS_VERSION}"
end

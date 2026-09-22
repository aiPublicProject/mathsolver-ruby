Gem::Specification.new do |s|
  s.name = 'mathsolver'
  s.version = '0.1.0'
  s.summary = 'BYOK AI math solver with independent verification'
  s.description = 'Bring your own OpenAI-compatible API key; answers are verified by local arithmetic expression evaluation before they reach you.'
  s.authors = ['mathsolver.help']
  s.homepage = 'https://mathsolver.help'
  s.license = 'MIT'
  s.required_ruby_version = '>= 2.7'
  s.files = Dir['lib/**/*.rb'] + ['README.md', 'LICENSE']
  s.metadata = { 'source_code_uri' => 'https://github.com/mathsolver-help/mathsolver-ruby',
                 'homepage_uri' => 'https://mathsolver.help' }
end

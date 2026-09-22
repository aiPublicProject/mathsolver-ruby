require 'minitest/autorun'
require_relative '../lib/mathsolver'

GOOD = { answer: 4, steps: ['Subtract 3: 2x = 8', 'Divide by 2: x = 4'], verification: { expression: '(11-3)/2' } }.to_json
WRONG = { answer: 4, steps: ['...'], verification: { expression: '(11-3)/3' } }.to_json

class TestEval < Minitest::Test
  def test_precedence
    assert_in_delta 10, MathSolver.eval_expression('2*3+4')
    assert_in_delta 14, MathSolver.eval_expression('2+3*4')
    assert_in_delta 20, MathSolver.eval_expression('(2+3)*4')
    assert_in_delta 512, MathSolver.eval_expression('2^3^2')
    assert_in_delta(-9, MathSolver.eval_expression('-3^2'))
    assert_in_delta 1, MathSolver.eval_expression('10%3')
  end

  def test_functions
    assert_in_delta 4, MathSolver.eval_expression('sqrt(16)')
    assert_in_delta 3, MathSolver.eval_expression('min(3,5)')
    assert_in_delta Math::PI, MathSolver.eval_expression('pi')
    assert_in_delta 3, MathSolver.eval_expression('log(1000)')
  end

  def test_rejects_bad
    ['system("x")', '1+2)', 'foo(1)', ''].each do |bad|
      assert_raises(MathSolver::Error) { MathSolver.eval_expression(bad) }
    end
  end
end

class TestClient < Minitest::Test
  def test_constructor_validation
    e = assert_raises(MathSolver::Error) { MathSolver::Client.new(api_key: '') }
    assert_equal 'NO_API_KEY', e.code
    e = assert_raises(MathSolver::Error) { MathSolver::Client.new(api_key: 'sk', base_url: 'not-a-url') }
    assert_equal 'BAD_BASE_URL', e.code
  end

  def test_verified_first_try
    calls = []
    seen = nil
    transport = lambda do |url, body, key|
      calls << 1
      seen = [url, body, key]
      GOOD
    end
    solver = MathSolver::Client.new(api_key: 'sk-test', base_url: 'https://api.deepseek.com/v1', model: 'deepseek-chat', transport: transport)
    r = solver.solve('2x + 3 = 11, solve for x')
    assert r.verified
    assert_equal 4, r.answer
    assert_equal 4, r.evaluated
    assert_equal 0, r.retries
    assert_equal 1, calls.length
    assert seen[0].end_with?('/chat/completions')
    assert_equal 'sk-test', seen[2]
  end

  def test_retry_recovers
    n = 0
    transport = lambda do |_url, _body, _key|
      n += 1
      n == 1 ? WRONG : GOOD
    end
    r = MathSolver::Client.new(api_key: 'sk', transport: transport).solve('2x+3=11')
    assert r.verified
    assert_equal 1, r.retries
  end

  def test_invalid_json_then_ok
    n = 0
    transport = ->(_u, _b, _k) { n += 1; n == 1 ? 'no json' : GOOD }
    r = MathSolver::Client.new(api_key: 'sk', transport: transport).solve('1+1')
    assert r.verified
  end

  def test_invalid_twice_raises
    transport = ->(_u, _b, _k) { 'nothing' }
    err = assert_raises(MathSolver::Error) { MathSolver::Client.new(api_key: 'sk', transport: transport).solve('1+1') }
    assert_equal 'INVALID_JSON', err.code
  end

  def test_no_api_key
    err = assert_raises(MathSolver::Error) { MathSolver::Client.new(api_key: '') }
    assert_equal 'NO_API_KEY', err.code
  end

  def test_http_error_no_retry
    calls = 0
    transport = lambda do |_u, _b, _k|
      calls += 1
      raise MathSolver::Error.new('HTTP_ERROR', '401')
    end
    err = assert_raises(MathSolver::Error) { MathSolver::Client.new(api_key: 'sk', transport: transport).solve('1+1') }
    assert_equal 'HTTP_ERROR', err.code
    assert_equal 1, calls
  end

  def test_still_wrong_unverified
    transport = ->(_u, _b, _k) { WRONG }
    r = MathSolver::Client.new(api_key: 'sk', transport: transport).solve('2x+3=11')
    refute r.verified
    assert_equal 1, r.retries
  end
end

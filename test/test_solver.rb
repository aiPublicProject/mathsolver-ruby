require 'json'
require 'minitest/autorun'
require_relative '../lib/mathsolver'

# v0.2 protocol fixtures: the model returns program/steps/check — never an answer.
GOOD = { program: "let d = 11 - 3;\nlet x = d / 2;\nresult = x", steps: ['Subtract 3: 2x = 8', 'Divide by 2: x = 4'], check: '2*{x} + 3 - 11' }.to_json
NO_CHECK = { program: 'result = 0.15 * 80', steps: ['Compute 15% of 80'] }.to_json
WRONG_CHECK = { program: "let d = 11 - 3;\nresult = d / 2", steps: ['...'], check: '2*{x} + 3 - 12' }.to_json
BROKEN_PROGRAM = { program: 'result = undefinedvar + 1', steps: [] }.to_json

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

  def test_env_variables
    assert_in_delta 4, MathSolver.eval_expression('d / 2', { 'd' => 8.0 })
    assert_in_delta 4, MathSolver.eval_expression('x + y', { 'x' => 1.5, 'y' => 2.5 })
    assert_raises(MathSolver::Error) { MathSolver.eval_expression('d') } # undefined without env
    assert_in_delta 3, MathSolver.eval_expression('pi', { 'pi' => 3.0 }) # env shadows constant
  end

  def test_rejects_bad
    ['system("x")', '1+2)', 'foo(1)', ''].each do |bad|
      assert_raises(MathSolver::Error) { MathSolver.eval_expression(bad) }
    end
  end
end

class TestProgram < Minitest::Test
  def test_let_and_result
    assert_in_delta 4, MathSolver.run_program("let d = 11 - 3;\nlet x = d / 2;\nresult = x")
    assert_in_delta 12, MathSolver.run_program('let a = 3; let b = 4; a * b')
    assert_in_delta 12, MathSolver.run_program('0.15 * 80')
  end

  def test_rejects
    ['result = undefinedvar + 1', '', 'let a = 1; let b = 2'].each do |bad|
      e = assert_raises(MathSolver::Error) { MathSolver.run_program(bad) }
      assert_match(/\A(PROGRAM_|EXPR_)/, e.code)
    end
  end

  def test_check
    pass = MathSolver.run_check('2*{x} + 3 - 11', 4.0)
    assert pass[:passed]
    assert_in_delta 0, pass[:value]
    fail_ = MathSolver.run_check('2*{x} + 3 - 12', 4.0)
    refute fail_[:passed]
    assert_in_delta(-1, fail_[:value])
    assert MathSolver.run_check('80*15/100 - {x}', 12.0)[:passed]
  end
end

class TestClient < Minitest::Test
  def test_constructor_validation
    e = assert_raises(MathSolver::Error) { MathSolver::Client.new(api_key: '') }
    assert_equal 'NO_API_KEY', e.code
    e = assert_raises(MathSolver::Error) { MathSolver::Client.new(api_key: 'sk', base_url: 'not-a-url') }
    assert_equal 'BAD_BASE_URL', e.code
  end

  def transport_returning(sequences)
    n = 0
    lambda do |_url, _body, _key|
      reply = sequences[n] || sequences.last
      n += 1
      reply
    end
  end

  def test_answer_from_execution_first_try
    calls = 0
    seen = {}
    tr = lambda do |url, body, key|
      calls += 1
      seen = { url: url, body: body, key: key }
      GOOD
    end
    solver = MathSolver::Client.new(api_key: 'sk-test', base_url: 'https://api.deepseek.com/v1', model: 'deepseek-chat', transport: tr)
    r = solver.solve('2x + 3 = 11, solve for x')
    # 答案=执行产物(4), 代回检验=0
    assert r.verified
    assert_equal 0, r.retries
    assert_in_delta 4, r.answer
    assert_in_delta 0, r.check_value
    assert_equal 1, calls
    assert_equal 'https://api.deepseek.com/v1/chat/completions', seen[:url]
    assert_equal 'sk-test', seen[:key]
    assert_equal 'deepseek-chat', seen[:body][:model]
    assert_equal 0, seen[:body][:temperature]
    # 协议确认: 模型 JSON 里没有 answer 字段
    refute JSON.parse(GOOD).key?('answer')
  end

  def test_no_check_unverified
    solver = MathSolver::Client.new(api_key: 'sk', base_url: 'https://api.x', model: 'm', transport: transport_returning([NO_CHECK]))
    r = solver.solve('15% of 80')
    assert_in_delta 12, r.answer
    refute r.verified
    assert_nil r.check
    assert_nil r.check_value
  end

  def test_check_fail_retry_recovers
    solver = MathSolver::Client.new(api_key: 'sk', base_url: 'https://api.x', model: 'm', transport: transport_returning([WRONG_CHECK, GOOD]))
    r = solver.solve('2x+3=11')
    assert r.verified
    assert_equal 1, r.retries
    assert_in_delta 4, r.answer
  end

  def test_program_error_retry_recovers
    solver = MathSolver::Client.new(api_key: 'sk', base_url: 'https://api.x', model: 'm', transport: transport_returning([BROKEN_PROGRAM, GOOD]))
    r = solver.solve('2x+3=11')
    assert r.verified
    assert_in_delta 4, r.answer
  end

  def test_program_error_persists_throws
    solver = MathSolver::Client.new(api_key: 'sk', base_url: 'https://api.x', model: 'm', transport: transport_returning([BROKEN_PROGRAM]))
    e = assert_raises(MathSolver::Error) { solver.solve('2x+3=11') }
    assert_match(/\A(PROGRAM_|EXPR_)/, e.code)
  end

  def test_invalid_json_then_ok
    solver = MathSolver::Client.new(api_key: 'sk', base_url: 'https://api.x', model: 'm', transport: transport_returning(['no json', GOOD]))
    r = solver.solve('1+1')
    assert r.verified
  end

  def test_invalid_json_twice_raises
    solver = MathSolver::Client.new(api_key: 'sk', base_url: 'https://api.x', model: 'm', transport: transport_returning(['nothing']))
    e = assert_raises(MathSolver::Error) { solver.solve('1+1') }
    assert_equal 'INVALID_JSON', e.code
  end

  def test_http_error_no_retry
    calls = 0
    tr = lambda do |_url, _body, _key|
      calls += 1
      raise MathSolver::Error.new('HTTP_ERROR', '401')
    end
    solver = MathSolver::Client.new(api_key: 'sk', base_url: 'https://api.x', model: 'm', transport: tr)
    e = assert_raises(MathSolver::Error) { solver.solve('1+1') }
    assert_equal 'HTTP_ERROR', e.code
    assert_equal 1, calls
  end

  def test_check_still_failing_unverified
    solver = MathSolver::Client.new(api_key: 'sk', base_url: 'https://api.x', model: 'm', transport: transport_returning([WRONG_CHECK]))
    r = solver.solve('2x+3=11')
    assert_in_delta 4, r.answer # 程序执行结果仍在
    refute r.verified
    assert_equal 1, r.retries
  end
end

# HTTP-interface mock: swap the Client's http_post seam so the DEFAULT
# transport runs its real code path (URL, headers, body, status, envelope
# parsing) against synthetic OpenAI-shaped responses. No server, no sockets.
class TestHttpMock < Minitest::Test
  def mocked_solver(api_key, contents, statuses = [])
    n = 0
    solver = MathSolver::Client.new(api_key: api_key, base_url: 'https://mock.test/v1', model: 'mock-model')
    calls = []
    solver.http_post = lambda do |url, headers, body_json|
      i = n
      n += 1
      calls << { url: url, headers: headers, body: JSON.parse(body_json) }
      content = contents[i] || GOOD
      status = statuses[i] || 0
      status >= 300 ? [status, 'upstream boom'] : [200, { choices: [{ message: { content: content } }] }.to_json]
    end
    [solver, calls]
  end

  def test_full_round_trip
    solver, calls = mocked_solver('sk-mock', [GOOD])
    r = solver.solve('2x + 3 = 11, solve for x')
    assert r.verified
    assert_equal 0, r.retries
    assert_in_delta 4, r.answer
    assert_equal 1, calls.length
    assert_equal 'https://mock.test/v1/chat/completions', calls[0][:url]
    assert_equal 'Bearer sk-mock', calls[0][:headers]['Authorization']
    assert_equal 'mock-model', calls[0][:body]['model']
    assert_equal 0, calls[0][:body]['temperature']
    assert_equal 'system', calls[0][:body]['messages'][0]['role']
    assert_includes calls[0][:body]['messages'][0]['content'], 'STRICT JSON'
  end

  def test_corrective_retry_carries_reason
    solver, calls = mocked_solver('sk', [WRONG_CHECK, GOOD])
    r = solver.solve('2x+3=11')
    assert r.verified
    assert_equal 1, r.retries
    assert_equal 2, calls.length
    assert calls[1][:body]['messages'].any? { |m| m['content'].include?('failed verification') }
  end

  def test_invalid_json_reask
    solver, calls = mocked_solver('sk', ['certainly not json', GOOD])
    r = solver.solve('1+1')
    assert r.verified
    assert_equal 2, calls.length
  end

  def test_500_http_error_no_retry
    solver, calls = mocked_solver('sk', [], [500])
    e = assert_raises(MathSolver::Error) { solver.solve('1+1') }
    assert_equal 'HTTP_ERROR', e.code
    assert_equal 1, calls.length
  end

  def test_401_http_error
    solver, = mocked_solver('sk-bad', [], [401])
    e = assert_raises(MathSolver::Error) { solver.solve('1+1') }
    assert_equal 'HTTP_ERROR', e.code
  end
end

# smoke: real API (set SMOKE_API_KEY to run; key never touches git)
class TestSmoke < Minitest::Test
  def test_real_api
    key = ENV['SMOKE_API_KEY']
    skip 'smoke: set SMOKE_API_KEY to run' unless key && !key.empty?
    base = ENV['SMOKE_BASE_URL']
    base = 'https://api.openai.com/v1' if base.nil? || base.empty?
    model = ENV['SMOKE_MODEL']
    model = 'gpt-4o-mini' if model.nil? || model.empty?
    r = MathSolver::Client.new(api_key: key, base_url: base, model: model).solve('2x + 3 = 11, solve for x')
    puts "smoke: answer=#{r.answer} verified=#{r.verified} retries=#{r.retries}"
    assert r.verified
    assert_in_delta 4, r.answer
  end
end

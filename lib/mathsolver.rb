# mathsolver-ruby — BYOK AI math solver with execution-based verification (v0.2).
#
# Correctness model (PAL-style): the model never states the answer.
# It returns a small JavaScript-like PROGRAM; this gem executes the program
# deterministically and the execution output IS the answer.
# For equations, a CHECK expression ({x} placeholder) must evaluate to 0
# when the computed answer is substituted back into the original equation.

require 'json'

module MathSolver
  class Error < StandardError
    attr_reader :code
    def initialize(code, message)
      @code = code
      super(message)
    end
  end

  SYSTEM_PROMPT = <<~PROMPT
    You are a precise math solver.
    Reply with STRICT JSON only, no markdown fences, in this exact shape:
    {"program": "<string>", "steps": [<string>, ...], "check": "<string>"}
    Rules:
    - "program" is a small JavaScript-like program that computes the final answer.
      One statement per line (or ; separated). Allowed statements:
          let NAME = EXPRESSION
          result = EXPRESSION
      EXPRESSIONs may use numbers, + - * / % ^ ( ), the functions
      abs sqrt sin cos tan ln log exp floor ceil round min max
      (log is base 10, ln is natural), the constants pi and e, and any
      variable defined by an earlier let. The value assigned to "result"
      is the answer. Never state the answer as a number in text.
    - "steps" is an array of short plain-language explanation strings.
    - "check" is a verification expression containing the placeholder {x}.
      After solving, {x} is replaced by the computed answer and the whole
      expression must evaluate to 0.
      For equations, substitute the answer back into the original equation
      (e.g. 2x+3=11 -> "2*{x}+3-11").
      For arithmetic, recompute via a different path and subtract the answer
      (e.g. 15% of 80 -> "80*15/100-{x}"). Provide "check" whenever possible.
  PROMPT

  def self.correction_prompt(reason)
    "Your submission failed verification: #{reason}. " \
      'Re-derive the problem carefully and reply again with the same strict JSON shape.'
  end

  MODULE_FUNCS = {
    'abs' => ->(x) { x.abs }, 'sqrt' => ->(x) { Math.sqrt(x) },
    'sin' => ->(x) { Math.sin(x) }, 'cos' => ->(x) { Math.cos(x) }, 'tan' => ->(x) { Math.tan(x) },
    'ln' => ->(x) { Math.log(x) }, 'log' => ->(x) { Math.log10(x) }, 'exp' => ->(x) { Math.exp(x) },
    'floor' => ->(x) { x.floor.to_f }, 'ceil' => ->(x) { x.ceil.to_f }, 'round' => ->(x) { x.round.to_f },
    'min' => ->(*a) { a.min }, 'max' => ->(*a) { a.max }
  }.freeze
  CONSTANTS = { 'pi' => Math::PI, 'e' => Math::E }.freeze

  TOKEN_RE = /\s*(?:(\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|\.\d+)|([a-zA-Z_][a-zA-Z_0-9]*)|([-+*\/%^(),]))/
  LET_RE = /\Alet\s+([a-zA-Z_]\w*)\s*=\s*(.+)\z/
  ASSIGN_RE = /\A([a-zA-Z_]\w*)\s*=\s*(.+)\z/
  CHECK_X_RE = /\{\s*x\s*\}/i

  def self.tokenize(src)
    tokens = []
    pos = 0
    while pos < src.length
      m = TOKEN_RE.match(src, pos)
      raise Error.new('EXPR_BAD_CHAR', "unexpected character at #{pos}") if m.nil? || m.end(0) == pos
      pos = m.end(0)
      if m[1] then tokens << [:num, m[1].to_f]
      elsif m[2] then tokens << [:id, m[2]]
      else tokens << [m[3], nil]
      end
    end
    tokens
  end

  # Evaluate a pure arithmetic expression string. No eval() is used.
  # env maps variable names (case-sensitive, shadow pi/e) to values.
  def self.eval_expression(src, env = {})
    raise Error.new('EXPR_EMPTY', 'empty expression') if src.nil? || src.strip.empty?
    tokens = tokenize(src)
    box = [0]
    peek = -> { tokens[box[0]] }
    eat = -> {
      t = tokens[box[0]]
      raise Error.new('EXPR_SYNTAX', 'expected more tokens') unless t
      box[0] += 1
      t
    }
    parse_expr = nil
    parse_term = nil
    parse_unary = nil
    parse_power = nil
    parse_atom = -> {
      t = eat.call
      case t[0]
      when :num then t[1]
      when :id
        if env.key?(t[1])
          env[t[1]]
        else
          name = t[1].downcase
          if peek.call && peek.call[0] == '('
            eat.call
            args = [parse_expr.call]
            while peek.call && peek.call[0] == ','
              eat.call
              args << parse_expr.call
            end
            raise Error.new('EXPR_SYNTAX', 'expected )') unless eat.call[0] == ')'
            fn = MODULE_FUNCS[name]
            raise Error.new('EXPR_UNKNOWN_FUNC', "unknown function #{name}") unless fn
            fn.call(*args).to_f
          elsif CONSTANTS.key?(name) then CONSTANTS[name]
          else raise Error.new('EXPR_UNKNOWN_ID', "unknown identifier #{name}")
          end
        end
      when '('
        v = parse_expr.call
        raise Error.new('EXPR_SYNTAX', 'expected )') unless eat.call[0] == ')'
        v
      else raise Error.new('EXPR_SYNTAX', "unexpected token #{t[0]}")
      end
    }
    parse_power = -> {
      base = parse_atom.call
      if peek.call && peek.call[0] == '^'
        eat.call
        base**parse_unary.call
      else
        base
      end
    }
    parse_unary = -> {
      if peek.call && peek.call[0] == '-'
        eat.call
        -parse_unary.call
      elsif peek.call && peek.call[0] == '+'
        eat.call
        parse_unary.call
      else
        parse_power.call
      end
    }
    parse_term = -> {
      v = parse_unary.call
      while peek.call && %w[* / %].include?(peek.call[0])
        op = eat.call[0]
        r = parse_unary.call
        v = op == '*' ? v * r : (op == '/' ? v.to_f / r : v.to_f % r)
      end
      v
    }
    parse_expr = -> {
      v = parse_term.call
      while peek.call && %w[+ -].include?(peek.call[0])
        op = eat.call[0]
        r = parse_term.call
        v = op == '+' ? v + r : v - r
      end
      v
    }
    value = parse_expr.call
    raise Error.new('EXPR_TRAILING', 'trailing tokens') if box[0] != tokens.length
    raise Error.new('EXPR_NON_FINITE', 'non-finite result') unless value.finite?
    value
  end

  # Execute a model-generated program. Statements (one per line or ;
  # separated): let NAME = EXPR | NAME = EXPR | bare EXPR. The answer is
  # the value of `result`, else the last bare expression. The model never
  # states the answer as a number — execution output IS the answer.
  def self.run_program(src)
    raise Error.new('PROGRAM_EMPTY', 'empty program') if src.nil? || src.strip.empty?
    env = {}
    result_defined = false
    last_defined = false
    last_value = nil
    src.split(/[\n;]+/).each do |raw|
      line = raw.strip
      next if line.empty?
      if (m = LET_RE.match(line))
        env[m[1]] = eval_expression(m[2], env)
        result_defined = true if m[1] == 'result'
      elsif (m2 = ASSIGN_RE.match(line))
        env[m2[1]] = eval_expression(m2[2], env)
        result_defined = true if m2[1] == 'result'
      else
        last_value = eval_expression(line, env)
        last_defined = true
      end
    end
    return env['result'] if result_defined
    return last_value if last_defined
    raise Error.new('PROGRAM_NO_RESULT', 'program produced no result')
  end

  # Substitute the computed answer into a check expression ({x} placeholder)
  # and evaluate it. Returns { value:, passed: }; passed when ~0 (scaled
  # tolerance). Block-form gsub keeps the replacement literal.
  def self.run_check(check_src, answer)
    substituted = check_src.gsub(CHECK_X_RE) { "(#{answer})" }
    value = eval_expression(substituted)
    { value: value, passed: value.abs <= 1e-6 * [1.0, answer.abs].max }
  end

  def self.parse_solver_json(text)
    m = text.to_s.match(/\{[\s\S]*\}/m)
    raise Error.new('INVALID_JSON', 'no JSON object in reply') unless m
    require 'json'
    data = begin
      JSON.parse(m[0])
    rescue JSON::ParserError
      raise Error.new('INVALID_JSON', 'reply was not valid JSON')
    end
    program = data['program']
    unless program.is_a?(String) && !program.strip.empty?
      raise Error.new('INVALID_JSON', 'missing program')
    end
    steps = data['steps'].is_a?(Array) ? data['steps'].map(&:to_s) : []
    check = data['check'].is_a?(String) && !data['check'].strip.empty? ? data['check'] : nil
    { program: program, steps: steps, check: check }
  end

  # Real HTTP POST via Net::HTTP. Returns [status, raw body].
  REAL_HTTP_POST = lambda do |url, headers, body_json|
    require 'net/http'
    require 'uri'
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    req = Net::HTTP::Post.new(uri.request_uri, headers)
    req.body = body_json
    res = http.request(req)
    [res.code.to_i, res.body]
  end

  def self.content_from_response(status, raw)
    require 'json'
    raise Error.new('HTTP_ERROR', "API responded #{status}") if status >= 300
    content = begin
      JSON.parse(raw.to_s).dig('choices', 0, 'message', 'content')
    rescue JSON::ParserError, NoMethodError, TypeError
      nil
    end
    raise Error.new('HTTP_ERROR', 'missing message content') unless content.is_a?(String)
    content
  end

  DEFAULT_TRANSPORT = lambda do |url, body, api_key|
    status, raw = MathSolver::REAL_HTTP_POST.call(
      url,
      { 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{api_key}" },
      JSON.generate(body)
    )
    MathSolver.content_from_response(status, raw)
  end

  Result = Struct.new(:answer, :steps, :program, :check, :check_value, :verified, :retries, keyword_init: true)

  # BYOK client for an OpenAI-compatible endpoint. Instantiate once, solve many.
  #
  #   solver = MathSolver::Client.new(api_key: 'sk-...', base_url: 'https://api.deepseek.com/v1', model: 'deepseek-chat')
  #   result = solver.solve('2x + 3 = 11, solve for x')
  class Client
    def initialize(api_key:, base_url: 'https://api.openai.com/v1', model: 'gpt-4o-mini', transport: nil)
      raise MathSolver::Error.new('NO_API_KEY', 'api_key is required (BYOK)') if api_key.to_s.empty?
      @base = base_url.to_s.sub(%r{/+\z}, '')
      unless @base.start_with?('http://', 'https://')
        raise MathSolver::Error.new('BAD_BASE_URL', 'base_url must be an http(s) URL, e.g. https://api.deepseek.com/v1')
      end
      @api_key = api_key
      @base_url = base_url
      @model = model
      @transport = transport
      @http_post = MathSolver::REAL_HTTP_POST
    end

    attr_reader :model
    # Test seam for the HTTP interface below the default transport:
    # (url, headers, body_json) -> [status, raw body]; swap in tests, no sockets.
    attr_accessor :http_post

    def model=(m)
      @model = m
    end

    def solve(problem)
      api_key = @api_key
      model = @model
      base_url = @base
      transport = @transport || lambda do |url, body, key|
        status, raw = http_post.call(
          url,
          { 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{key}" },
          JSON.generate(body)
        )
        MathSolver.content_from_response(status, raw)
      end
      raise MathSolver::Error.new('NO_PROBLEM', 'problem must be non-empty') if problem.to_s.strip.empty?
      url = "#{base_url}/chat/completions"
      messages = [
        { role: 'system', content: SYSTEM_PROMPT },
        { role: 'user', content: problem }
      ]
      call = -> { transport.call(url, { model: model, messages: messages, temperature: 0 }, api_key) }

      begin
        parsed = MathSolver.parse_solver_json(call.call)
      rescue Error => e
        raise unless e.code == 'INVALID_JSON'
        messages << { role: 'assistant', content: 'invalid JSON' }
        messages << { role: 'user', content: 'Your reply was not valid JSON. Reply again with the exact strict JSON shape.' }
        parsed = MathSolver.parse_solver_json(call.call)
      end

      attempt = lambda do |p|
        begin
          answer = MathSolver.run_program(p[:program])
          out = { ok: true, answer: answer, check_value: nil, verified: false }
          if p[:check]
            r = MathSolver.run_check(p[:check], answer)
            out[:check_value] = r[:value]
            out[:verified] = r[:passed]
          end
          out
        rescue Error => e
          { ok: false, error: e }
        end
      end

      outcome = attempt.call(parsed)
      retries = 0
      unless outcome[:ok] && outcome[:verified]
        retries = 1
        reason = if outcome[:ok]
                   "check evaluated to #{outcome[:check_value]} instead of 0"
                 else
                   "program failed to execute (#{outcome[:error].code}: #{outcome[:error].message})"
                 end
        messages << { role: 'assistant', content: JSON.generate({ program: parsed[:program], steps: parsed[:steps], check: parsed[:check] }) }
        messages << { role: 'user', content: MathSolver.correction_prompt(reason) }
        second_parsed = MathSolver.parse_solver_json(call.call) # second failure raises
        second = attempt.call(second_parsed)
        raise second[:error] unless second[:ok] # PROGRAM_* error persisted after retry
        parsed = second_parsed
        outcome = second
      end

      Result.new(answer: outcome[:answer], steps: parsed[:steps], program: parsed[:program],
                 check: parsed[:check], check_value: outcome[:check_value],
                 verified: !!outcome[:verified], retries: retries)
    end
  end
end

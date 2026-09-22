# mathsolver-ruby — BYOK AI math solver with independent verification.
# An answer is only verified=true when the model's verification expression
# (pure arithmetic) is evaluated locally and matches the answer.

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
    {"answer": <number>, "steps": [<string>, ...], "verification": {"expression": "<string>"}}
    Rules:
    - "answer" must be a single number (the final result).
    - "steps" must be an array of short plain-language explanation strings.
    - "verification.expression" must be a pure arithmetic expression that
      evaluates to the answer. Allowed: numbers, + - * / % ^ ( ), and the
      functions abs sqrt sin cos tan ln log exp floor ceil round min max
      (log is base 10, ln is natural), and the constants pi and e.
    - The expression must recompute the answer independently.
  PROMPT

  MODULE_FUNCS = {
    'abs' => ->(x) { x.abs }, 'sqrt' => ->(x) { Math.sqrt(x) },
    'sin' => ->(x) { Math.sin(x) }, 'cos' => ->(x) { Math.cos(x) }, 'tan' => ->(x) { Math.tan(x) },
    'ln' => ->(x) { Math.log(x) }, 'log' => ->(x) { Math.log10(x) }, 'exp' => ->(x) { Math.exp(x) },
    'floor' => ->(x) { x.floor.to_f }, 'ceil' => ->(x) { x.ceil.to_f }, 'round' => ->(x) { x.round.to_f },
    'min' => ->(*a) { a.min }, 'max' => ->(*a) { a.max }
  }.freeze
  CONSTANTS = { 'pi' => Math::PI, 'e' => Math::E }.freeze

  TOKEN_RE = /\s*(?:(\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|\.\d+)|([a-zA-Z_][a-zA-Z_0-9]*)|([-+*\/%^(),]))/

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
  def self.eval_expression(src)
    raise Error.new('EXPR_EMPTY', 'empty expression') if src.nil? || src.strip.empty?
    tokens = tokenize(src)
    box = [0]
    # simple recursive functions using box for position
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

  def self.numerically_equal(a, b)
    (a - b).abs <= 1e-6 * [1.0, a.abs, b.abs].max
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
    answer = data['answer']
    if answer.is_a?(String)
      mm = answer.match(/-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/)
      answer = mm ? mm[0].to_f : nil
    end
    raise Error.new('INVALID_JSON', 'missing numeric answer') unless answer.is_a?(Numeric)
    expression = data.dig('verification', 'expression')
    raise Error.new('INVALID_JSON', 'missing verification.expression') unless expression.is_a?(String)
    steps = data['steps'].is_a?(Array) ? data['steps'].map(&:to_s) : []
    { answer: answer.to_f, steps: steps, expression: expression }
  end

  DEFAULT_TRANSPORT = lambda do |url, body, api_key|
    require 'net/http'
    require 'uri'
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{api_key}")
    req.body = JSON.generate(body)
    res = http.request(req)
    raise Error.new('HTTP_ERROR', "API responded #{res.code}") unless res.is_a?(Net::HTTPSuccess)
    content = JSON.parse(res.body).dig('choices', 0, 'message', 'content')
    raise Error.new('HTTP_ERROR', 'missing message content') unless content.is_a?(String)
    content
  end

  Result = Struct.new(:answer, :steps, :expression, :evaluated, :verified, :retries, keyword_init: true)

  # BYOK client for an OpenAI-compatible endpoint. Instantiate once, solve many.
  #
  #   solver = MathSolver::Client.new(api_key: 'sk-...', base_url: 'https://api.deepseek.com/v1', model: 'deepseek-chat')
  #   result = solver.solve('2x + 3 = 11, solve for x')
  class Client
    def initialize(api_key:, base_url: 'https://api.openai.com/v1', model: 'gpt-4o-mini', transport: MathSolver::DEFAULT_TRANSPORT)
      raise MathSolver::Error.new('NO_API_KEY', 'api_key is required (BYOK)') if api_key.to_s.empty?
      @base = base_url.to_s.sub(%r{/+\z}, '')
      unless @base.start_with?('http://', 'https://')
        raise MathSolver::Error.new('BAD_BASE_URL', 'base_url must be an http(s) URL, e.g. https://api.deepseek.com/v1')
      end
      @api_key = api_key
      @base_url = base_url
      @model = model
      @transport = transport
    end

    attr_reader :model

    def model=(m)
      @model = m
    end

      def solve(problem)
        api_key = @api_key
        model = @model
        transport = @transport
        base_url = @base
        raise MathSolver::Error.new('NO_PROBLEM', 'problem must be non-empty') if problem.to_s.strip.empty?
        url = "#{base_url.to_s.sub(%r{/+\z}, '')}/chat/completions"
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

      evaluate = lambda do |p|
        ev = begin
          MathSolver.eval_expression(p[:expression])
        rescue Error
          nil
        end
        [ev, ev && MathSolver.numerically_equal(ev, p[:answer])]
      end

      evaluated, verified = evaluate.call(parsed)
      retries = 0
      unless verified
        retries = 1
        messages << { role: 'assistant', content: JSON.generate(parsed) }
        messages << { role: 'user', content: "Your verification expression evaluated to #{evaluated || 'an error'}, which does not match your answer #{parsed[:answer]}. Re-derive the problem carefully and reply again with the same strict JSON shape." }
        begin
          second = MathSolver.parse_solver_json(call.call)
          ev2, ok2 = evaluate.call(second)
          evaluated = ev2 unless ev2.nil?
          parsed = second if ok2
          verified = true if ok2
        rescue Error
        end
      end

      Result.new(answer: parsed[:answer], steps: parsed[:steps], expression: parsed[:expression],
                 evaluated: evaluated, verified: !!verified, retries: retries)
    end
  end
end

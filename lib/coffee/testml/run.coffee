require '../testml'
require 'ingy-prelude' if TestML.env['TESTML_DEVEL']
lodash = require 'lodash'

module.exports =
class TestML.Run
  @vtable:
    '==': [
      'assert_eq',
      'assert_%1_eq_%2',
        'str,str': ''
        'num,num': ''
        'bool,bool': ''
    ]

    '~~': [
      'assert_has',
      'assert_%1_has_%2',
        'str,str': ''
        'str,list': ''
        'list,str': ''
        'list,list': ''
    ]

    '=~': [
      'assert_like',
      'assert_%1_like_%2',
        'str,regex': ''
        'str,list': ''
        'list,regex': ''
        'list,list': ''
    ]

    '.'  : 'exec_dot'
    '%'  : 'for_each'
    '%()': 'pick_loop'
    '()' : 'pick_exec'

    '&'  : 'call_func'
    "$''": 'get_str'
    ':'  : 'get_hash'
    '[]' : 'get_list'
    '*'  : 'get_point'
    '='  : 'set_var'
    '||=': 'or_set_var'

  @types:
    string: 'str'
    number: 'num'
    boolean: 'bool'
    testml:
      '=>': 'func'
      '/': 'regex'
      '!': 'error'
      '?': 'native'
    group:
      Object: 'hash'
      Array: 'list'

  file: undefined
  version: undefined
  code: undefined
  data: undefined

  bridge: undefined
  stdlib: undefined

  vars: {}
  block: undefined
  warned_only: false
  error: null
  throw: null

  #----------------------------------------------------------------------------
  constructor: (params={})->
    { @file,
      @bridge,
      @stdlib,
      testml={},
    } = params

    { testml,
      @code,
      @data
    } = testml

    @version = testml

    global._ = lodash if not TestML.browser
    return

  from_file: (@file)->
    fs = require 'fs'

    {testml, @code, @data} = JSON.parse if @file == '-' \
      then fs.readFileSync('/dev/stdin').toString() \
      else fs.readFileSync(@file).toString()

    @version = testml

    return @

  test: ->
    @testml_begin()

    for statement in @code
      @exec_expr statement

    @testml_end()

    return

  #----------------------------------------------------------------------------
  getp: (name)->
    return unless @block
    value = @block.point[name]
    value = @exec value if value?
    value

  getv: (name)->
    return @vars[name]

  setv: (name, value)->
    @vars[name] = value
    return

  #----------------------------------------------------------------------------
  exec: (expr)->
    @exec_expr(expr)[0]

  exec_expr: (expr, context=[])->
    return [expr] unless @type(expr) == 'expr'

    args = _.clone expr

    opcode = name = args.shift()
    if call = @constructor.vtable[opcode]
      call = call[0] if _.isArray call
      # Might need to pass context to => calls here.
      return_ = @[call](args...)

    else
      args.unshift (_.reverse context)...

      if (value = @vars[name])?
        if args.length
          die "Variable '#{name}' has args but is not a function" \
            unless @type value == 'func'
          return_ = @exec_func value, args
        else
          return_ = value

      else if name.match /^[a-z]/
        return_ = @call_bridge name, args

      else if name.match /^[A-Z]/
        return_ = @call_stdlib name, args

      else
        throw "Can't resolve TestML function '#{name}'"

    return if return_ == undefined then [] else [return_]

  exec_dot: (calls...)->
    context = []

    @error = null
    for call in calls
      if ! @error
        try
          if @type(call) == 'func'
            @exec_func call, context[0]
            context = []
          else
            context = @exec_expr call, context
          if @thrown
            @error = @cook @thrown
            @thrown = null
        catch e
          @error = @call_stdlib 'Error', ["#{e}"]
      else
        if call[0] == 'Catch'
          context = [@error]
          @error = null

    throw 'Uncaught Error: ' + @error[1].msg if @error

    return unless context.length
    return context[0]

  for_each: (list, expr)->
    list = @exec list
    expr = @exec expr

    for item in list[0]
      @vars._ = [item]
      if @type(expr) == 'func'
        if expr[1].length == 0
          @exec_func expr
        else
          @exec_func expr, [item]
      else
        @exec_expr expr

  pick_loop: (list, expr)->
    for block in @data
      @block = block

      if block.point.ONLY and ! @warned_only
        @err "Warning: TestML 'ONLY' in use."
        @warned_only = true

      @exec_expr ['()', list, expr]

    @block = undefined

    return

  pick_exec: (list, expr)->
    pick = true
    for point in list
      if (point.match(/^\*/) and ! @block.point[point[1..]]?) or
          (point.match(/^\!\*/) and @block.point[point[2..]]?)
        pick = false
        break

    if pick
      if @type(expr) == 'func'
        @exec_func expr
      else
        @exec_expr expr

  exec_func: ([op, signature, statements], args=[])->
    if signature.length > 1 and args.length == 1 and @type(args) == 'list'
      args = args[0]

    if signature.length != args.length
      throw "TestML function expected '#{signature.length}' arguments, but was called with '#{args.length}' arguments"

    for i, v of signature
      @vars[v] = args[i]

    for statement in statements
      @exec_expr statement

    return

  call_func: (func)->
    name = func[0]
    func = @exec func
    throw "Tried to call '#{name}' but is not a function" \
      unless func? and @type(func) == 'func'
    @exec_func func

  get_str: (string)->
    return @interpolate string

  get_hash: (hash, key)->
    hash = @exec hash
    key = @exec key
    type = @type hash

    @cook switch
      when type == 'hash' then hash[0][key]
      when type == 'error' then hash[1][key]
      else
        "Can't lookup hash key on value of type '#{type}'"

  get_list: (list, index)->
    list = @exec list
    return @cook list[0][index]

  get_point: (name)->
    return @getp name

  set_var: (name, expr)->
    if @type(expr) == 'func'
      @setv name, expr
    else
      @setv name, @exec expr
    return

  or_set_var: (name, expr)->
    return if @vars[name]?

    if @type(expr) == 'func'
      @setv name, expr
    else
      @setv name, @exec expr
    return


  assert_eq: (left, right, label)->
    @vars.Got = got = @exec left
    @vars.Want = want = @exec right
    method = @get_method '==', got, want
    @[method] got, want, label
    return

  assert_str_eq_str: (got, want, label)->
    @testml_eq got, want, @get_label label

  assert_num_eq_num: (got, want, label)->
    @testml_eq got, want, @get_label label

  assert_bool_eq_bool: (got, want, label)->
    @testml_eq got, want, @get_label label


  assert_has: (left, right, label)->
    got = @exec left
    want = @exec right
    method = @get_method '~~', got, want
    @[method] got, want, label
    return

  assert_str_has_str: (got, want, label)->
    @vars.Got = got
    @vars.Want = want
    @testml_has got, want, @get_label label

  assert_str_has_list: (got, want, label)->
    for str in want[0]
      @assert_str_has_str got, str, label

  assert_list_has_str: (got, want, label)->
    @vars.Got = got
    @vars.Want = want
    @testml_list_has got[0], want, @get_label label

  assert_list_has_list: (got, want, label)->
    for str in want[0]
      @assert_list_has_str got, str, label


  assert_like: (left, right, label)->
    got = @exec left
    want = @exec right
    method = @get_method '=~', got, want
    @[method] got, want, label
    return

  assert_str_like_regex: (got, want, label)->
    @vars.Got = got
    @vars.Want = "/#{want[1]}/"
    want = @uncook want
    @testml_like got, want, @get_label label

  assert_str_like_list: (got, want, label)->
    for regex in want[0]
      @assert_str_like_regex got, regex, label

  assert_list_like_regex: (got, want, label)->
    for str in got[0]
      @assert_str_like_regex str, want, label

  assert_list_like_list: (got, want, label)->
    for str in got[0]
      for regex in want[0]
        @assert_str_like_regex str, regex, label

  #----------------------------------------------------------------------------
  type: (value)->
    throw "Can't get type of undefined value" \
      if typeof value == 'undefined'

    return 'null' if value == null

    types = @constructor.types
    type = types[typeof value] ||
      types[name = value.constructor.name] ||
        if name == 'Array'
          if value.length == 0
            'none'
          else
            if typeof value[0] == 'string'
              types.testml[value[0]] || 'expr'
            else
              types.group[value[0].constructor.name] || 'native'
        else
          throw "Bad TestML internal value: '#{name}'"

    return type \
      or throw "Can't get type of #{require('util').inspect value}"

  cook: (value)->
    return [] if value == undefined
    return null if value == null
    name = value.constructor.name
    return value if name.match /^(?:String|Number|Boolean)$/
    return [value] if name.match /^(?:Array|Object)$/

    return ['/', value] if name == 'RegExp'
    return ['!', value] if name == 'TestMLError'
    return value['func'] if name == 'TestMLFunction'
    return ['?', value]

  uncook: (value)->
    type = @type value

    switch
      when type.match /^(?:str|num|bool|null)$/ then value
      when type.match /^(?:list|hash)$/ then value[0]
      when type.match /^(?:error|native)$/ then value[1]
      when type == 'func' then new TestMLFunction value
      when type == 'regex'
        if typeof value[1] == 'string' then new RegExp value[1]
        else value[1]
      when type == 'none' then undefined
      else throw "Can't uncook '#{require('util').inspect value}'"

  call_stdlib: (name, args)->
    @stdlib ||= new(require '../testml/stdlib') @

    call = _.lowerCase(name).replace /\s+/g, ''
    throw "Unknown TestML Standard Library function: '#{name}'" \
      unless @stdlib[call]

    args = _.map args, (x)=> @uncook @exec x

    @cook @stdlib[call](args...)

  call_bridge: (name, args)->
    @bridge ||= new(require process.env.TESTML_BRIDGE)

    call = name.replace /-/g, '_'
    throw "Can't find bridge function: '#{name}'" \
      unless @bridge[call]

    args = _.map args, (x)=> @uncook @exec x

    return_ = @bridge[call](args...)

    return unless return_?

    @cook return_

  get_method: (key, args...)->
    sig = []
    for arg in args
      sig.push @type arg
    sig_str = sig.join ','

    entry = @constructor.vtable[key]
    [name, pattern, vtable] = entry
    method = vtable[sig_str] ||
      pattern.replace /%(\d+)/g, (m, num)-> sig[num - 1]

    throw "Can't resolve #{name}(#{sig_str})" unless method
    throw "Method '#{method}' does not exist" unless @[method]

    return method

  get_label: (label_expr='')->
    label = @exec label_expr

    label ||= @getv('Label') || ''
    block_label = if @block? then @block.label else ''

    if label
      label = label.replace /^\+/, block_label
      label = label.replace /\+$/, block_label
      label = label.replace /\{\+\}/, block_label
    else
      label = block_label

    return @interpolate label, true

  interpolate: (string, label=false)->
    transform = (value)=>
      if label
        switch
          when @type(value).match /^(?:list|hash)$/ then \
            JSON.stringify(value[0]).replace /"/g, ''
          else String(value).replace /\n/g, '␤'
      else
        switch
          when @type(value).match /^(?:list|hash)$/ then \
            JSON.stringify(value[0]).replace /"/g, ''
          else String value

    transform1 = (m, name)=>
      return '' unless (value = @vars[name])?
      transform value

    transform2 = (m, name)=>
      return '' unless (value = @block?.point[name])?
      transform value

    string = string.replace /\{([\-\w]+)\}/g, transform1
    string = string.replace /\{\*([\-\w]+)\}/g, transform2

    return string

  #----------------------------------------------------------------------------
  test_types: ->
    class Bad

    console.log "null   - #{@type null}"
    console.log "none   - #{@type []}"

    console.log "str    - #{@type ""}"
    console.log "num    - #{@type 1}"
    console.log "bool   - #{@type false}"

    console.log "list   - #{@type [[]]}"
    console.log "hash   - #{@type [{}]}"

    console.log "regex  - #{@type ['/','']}"
    console.log "func   - #{@type ['=>','']}"
    console.log "error  - #{@type ['!','']}"
    console.log "native - #{@type ['?','']}"
    console.log "expr   - #{@type ['foo']}"

    console.log "new Bad   - #{try @type new Bad catch e then e}"
    console.log "new Regex - #{try @type /x/ catch e then e}"
    console.log "undefined - #{try @type() catch e then e}"

    throw "Tested TestML internal types"

# (new TestML.Run).test_types()

#------------------------------------------------------------------------------
TestML.Block = class
  constructor: ({@label, @point, @user=''})->

TestMLFunction = class
  constructor: (@func)->

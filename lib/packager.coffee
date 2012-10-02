convoy = require 'convoy'
STYLUS = require 'stylus'
FS     = require 'fs'
PATH   = require 'path'
JOIN   = PATH.join

Parser     = STYLUS.Parser
Normalizer = require 'stylus/lib/visitor/normalizer'


# Workaround [#241](https://github.com/LearnBoost/stylus/issues/241)
# in Stylus that would skip imported literals
#
class Compiler extends STYLUS.Compiler

  visitBlock: (block) ->
    if not block.hasProperties
      arr = []
      block.nodes.forEach (node) =>
        arr.push(@visit node) if node.nodeName == 'literal'
      arr.push "\n"
      @buf += arr.join "\n"

    return STYLUS.Compiler.prototype.visitBlock.apply @, arguments

# Replace the default import with one that uses the AssetPackager to
# find dependencies. This allows importing styl files from other packages.
class Evaluator extends STYLUS.Evaluator

  visitImport: (imported) ->

    @return++

    root = @root
    path = @visit(imported.path).first
    packager   = @options.packager
    sourcePath = @importStack[@importStack.length-1] or @options.sourcePath 
    includeCSS = @options.includeCSS

    @return--

    # url() passed
    return imported if 'url' == path.name

    # ensure string
    throw new Error '@import string expected' unless path.string
    name = path = path.string

    # CSS literal
    found = packager.resolve path, PATH.dirname(sourcePath),
      paths: [PATH.dirname(sourcePath)]

    if ~found.indexOf '.css'
      literal = true
      unless includeCSS
        imported.path = found
        return imported

    # lookup path
    imported.path    = found
    imported.dirname = PATH.dirname found
    @paths.push imported.dirname
    @options._imports.push imported if @options._imports

    # Throw if import failed
    throw new Error 'failed to locate @import ' + path if not found

    @importStack.push found
    STYLUS.nodes.filename = found;

    # make sure path ends up in watch & mtime are updated for caching
    body = FS.readFileSync found, 'utf8'
    packager.watchPath found
    foundMtime = FS.statSync(found).mtime
    if @options?.asset
      @options.asset.mtime = Math.max(foundMtime, @options.asset.mtime)

    if literal
      block = new STYLUS.nodes.Literal body
    else
      parser = new Parser body,
        root: new STYLUS.nodes.Block() # prevent double-include

      try
        block = parser.parse()
      catch err
        err.filename = found
        err.lineno   = parser.lexer.lineno
        err.input    = body
        throw err
        
    # Evaluate imported "root"
    block.parent = root
    block.scope  = false
    ret = @visit block  

    @paths.pop()
    @importStack.pop()
    ret

# TODO: It would be nice if CSS assets had a common export format so that 
# we could mix and match different sources.
#
#  css_asset:
#    body: 'string' <- just included after expansion
#    children: []   <- other CSS assets included in this one
#    lessAST | stylusAST: node <- lib-specific AST that includes mixins etc.
#
StylusCompiler = (asset, packager, done) ->
  FS.readFile asset.path, 'utf8', (err, body) ->
    return done(err) if err

    asset.mtime = FS.statSync(asset.path).mtime

    # taken from the Stylus.render() method
    options =
      packager:   packager
      sourcePath: asset.path
      includeCSS: @includeCSS != false
      asset:      asset
      imports:    [JOIN(__dirname, '..', 'node_modules', 'stylus', 'lib', 'functions')]

    parser = new Parser body, options

    try
      ast = parser.parse()
      ast = new Evaluator(ast, options).evaluate()
      ast = new Normalizer(ast, options).normalize()
      body = new Compiler(ast, options).compile()
      asset.ast = ast
      asset.body = body
      done()

    catch err
      err = STYLUS.utils.formatException err,
          filename: err.filename or asset.path
          lineno:   err.lineno   or parser.lexer.lineno
          input:    err.input    or body
      done err    


module.exports = convoy.packager
  type: 'text/css'
  compilers:
    '.css': convoy.plugins.GenericCompiler
    '.styl': StylusCompiler

  analyzer: convoy.plugins.GenericAnalyzer
  linker: convoy.plugins.CSSLinker
  minifier: convoy.plugins.UglifyCSSMinifier


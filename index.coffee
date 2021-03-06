require './app/lib/coffee-support'
async = require 'async'
crypto = require 'crypto'
express = require 'express'
http = require 'http'
path = require 'path'
fs = require 'fs'
net = require 'net'
nodemailer = require 'nodemailer'
_ = require 'underscore'
FSStore = require('./app/lib/connect-fs')(express)
Plugin = require './app/plugin'
require './app/env' # Fix/load/check environmental variables
require './app/lib/jade-exclamation'

makeIntegerIfPossible = (str) ->
  return parseInt(str, 10) if str?.match?(/^[0-9]+$/)
  str

app = express()
require('./app/lib/email')(app)
if global.gc
  console.log "MEMORY DEBUG MODE ENABLED"
  app.use (req, res, next) ->
    property = 'heapUsed'
    global.gc()
    startMB = process.memoryUsage()[property]/(1024*1024)
    res.once 'finish', ->
      endMB = process.memoryUsage()[property]/(1024*1024)
      #console.log "#{req.method} #{req.path} used #{(endMB-startMB).toFixed(3)}MB (#{endMB.toFixed(3)}MB - #{startMB.toFixed(3)}MB)"
      console.log "\t #{(endMB-startMB).toFixed(3)}MB \t- #{req.method}\t#{req.path}\t\t(#{endMB.toFixed(3)}MB - #{startMB.toFixed(3)}MB)"
      global.gc()
      console.log "#{endMB.toFixed(3)}MB / #{(process.memoryUsage().heapTotal/(1024*1024)).toFixed(3)}MB"
    next()
app.plugins = []
app.getPlugin = (id) ->
  return plugin for plugin in app.plugins when plugin.identifier is id
  return
app.pluginHook = Plugin.hook app

app.updateEmailTransport = ->
  if app.emailSetting.meta.settings?.service?.length
    app.mailTransport = nodemailer.createTransport "SMTP",
      service: app.emailSetting.meta.settings.service
      host: app.emailSetting.meta.settings.host
      auth:
        user: app.emailSetting.meta.settings.username
        pass: app.emailSetting.meta.settings.password
  else
    app.mailTransport = nodemailer.createTransport("Direct", {debug: true})

app.path = __dirname
app.locals._appPath = app.path

app.set 'trust proxy', true # Required for nginx/etc
app.set 'port', makeIntegerIfPossible(process.env.PORT) ? 1337
app.locals.basedir = path.join __dirname, 'app', 'views'
app.set 'views', app.locals.basedir
app.set 'view engine', 'jade'

if __dirname isnt process.cwd()
  app.use express.static(path.join(process.cwd(), 'public'))

app.use (req, res, next) ->
  req.app = app
  res.locals.restartRequired = app.restartRequired ? false
  next()
app.use require('./app/middleware/logging')(app)
app.use require('./app/middleware/http-error')()
app.use express.cookieParser(process.env.SECRET)

sessionStore = new FSStore

app.use express.session
  secret: process.env.SECRET
  store: sessionStore

app.use (req, res, next) -> # Custom themes
  try
    if req.query.unsafe?
      delete req.session.safe
    if req.query.safe?
      req.session.safe = 1
    if req.session.safe
      throw new Error "Safe mode"
    themeName = app.themeSetting.meta.settings.identifier
    themePlugin = Plugin.load themeName
    themePlugin = null unless themePlugin.themeMiddleware?
  if themePlugin
    res.locals.basedir = path.join themePlugin.path, 'views'
    themePlugin.themeMiddleware(req, res, next)
  else
    res.locals.basedir = path.join __dirname, 'app', 'views'
    next()
  return

app.use require('./app/middleware/stylus')()
app.use express.static(path.join(__dirname, 'public'))

app.use express.bodyParser()
app.use express.methodOverride()

app.configure 'development', ->
  app.use express.errorHandler()
app.use require('./app/models').middleware()
app.use require('./app/lib/passport').initialize()
app.use require('./app/lib/passport').session()
app.use require('./app/middleware/template')(app)

app.use app.router
require('./app/router')(app)

app.use require('./app/middleware/404')()
app.use require('./app/middleware/error-handler')()

listen = (port) ->
  server = http.createServer(app)
  server.on 'error', (err) ->
    if err?.code is 'EADDRINUSE'
      app.logger.error "Port '#{port}' in use"
    else
      app.logger.error "Could not listen on socket '#{port}': #{err}"
    process.exit 1
  server.listen port, ->
    if typeof port is 'string'
      fs.chmod port, '0666'
    app.logger.info "Express server listening on port " + port

start = ->
  port = app.get('port')
  if typeof port is 'string'
    # Unix socket - see if it's in use
    socket = new net.Socket
    socket.on 'connect', ->
      app.logger.error "Socket in use"
      process.exit 1
    socket.on 'error', (err) ->
      if err?.code is 'ECONNREFUSED'
        # No-one's listening
        fs.unlink port, (err) ->
          if err
            app.logger.error "Couldn't delete old socket."
            process.exit 1
          app.logger.info "Liberated unused socket."
          listen port
      else if err?.code is 'ENOENT'
        listen port
      else
        app.logger.error "Could not listen on socket '#{port}': #{err}"
        process.exit 1
    socket.connect port
  else
    # TCP socket
    listen port

checkRoles = (start) ->
  app.models.Role.find (err, roles) ->
    throw err if err
    for role in roles ? []
      hasBase = true if role.id is 1
      hasOwner = true if role.id is 2
    throw new Error("Required role is missing, try 'npm run setup'") unless hasBase and hasOwner
    start()

loadPlugins = (start) ->
  dependencies = {}
  files = fs.readdirSync("#{__dirname}/plugins")
  for moduleName in files when moduleName.match /^members-area-/
    try
      app.plugins.push Plugin.load "#{__dirname}/plugins/#{moduleName}", app
    catch e
      console.error "Could not load local '#{moduleName}' plugin: #{e}"
  try
    packageJson = require("#{process.cwd()}/package.json")
    dependencies = _.extend {},
      (packageJson.optionalDependencies ? {})
      packageJson.dependencies
  for moduleName of dependencies when moduleName.match /^members-area-/
    try
      app.plugins.push Plugin.load moduleName, app
    catch e
      console.error "Could not load '#{moduleName}' plugin: #{e}"
  loadPlugin = (plugin, done) ->
    plugin.load(done)
  async.mapSeries app.plugins, loadPlugin, (err) ->
    throw err if err
    checkRoles(start)

loadSettings = (start) ->
  app.models.Setting.find()
  .where(name:['email', 'theme', 'site'])
  .run (err, settings) ->
    throw err if err
    for setting in settings
      emailSetting = setting if setting.name is 'email'
      themeSetting = setting if setting.name is 'theme'
      siteSetting = setting if setting.name is 'site'
    throw new Error "No email setting, try seeding the database" unless emailSetting
    unless themeSetting
      themeSetting = new app.models.Setting
        name: 'theme'
        meta:
          settings: {}
      themeSetting.save ->
    unless siteSetting
      siteSetting = new app.models.Setting
        name: 'site'
        meta:
          settings: {}
      siteSetting.save ->
    app.emailSetting = emailSetting
    app.updateEmailTransport()
    app.themeSetting = themeSetting
    app.siteSetting = siteSetting
    loadPlugins(start)

connectToDb = (start) ->
  require('orm').connect process.env.DATABASE_URL, (err, db) ->
    throw err if err
    require('./app/models') app, db, (err, models) ->
      throw err if err
      app.globalDb = db
      app.models = models
      loadSettings(start)

app.start = (_start = start) ->
  # XXX: merge these two together.
  unless process.env.SERVER_ADDRESS
    console.error "ERROR: You must set the 'SERVER_ADDRESS' environmental variable."
    process.exit 1
  unless process.env.SECRET
    crypto.randomBytes 18, (err, bytes) ->
      console.error "ERROR: You must set the 'SECRET' environmental variable, e.g."
      console.error "    SECRET=\"#{bytes.toString('base64') ? "SecretStringHere"}\""
      process.exit 1
    return
  connectToDb(_start)

if require.main is module
  app.start()

module.exports = app

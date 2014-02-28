EventEmitter = require('events').EventEmitter
fs = require 'fs'
async = require 'async'
migrator = require './lib/migrator'
_ = require 'underscore'

class Plugin extends EventEmitter
  @hook: (app) ->
    app.pluginHooks = {}
    processHook = (hookName, options, callback) ->
      prioritisedHooks = app.pluginHooks[hookName] ? {}
      priorities = Object.keys prioritisedHooks
      priorities.sort (a, b) -> parseInt(a, 10) - parseInt(b, 10)
      handleHook = (hook, next) ->
        if hook.length is 1 # No callback, do it live!
          hook(options)
          return process.nextTick next
        done = ->
          done = -> # Prevent calling twice
          clearTimeout timer
          next()
        timer = setTimeout done, 3000 # Give hook just 3 seconds to do its thang
        hook options, done
      handlePriority = (priority, next) ->
        async.each prioritisedHooks[priority], handleHook, next
      async.eachSeries priorities, handlePriority, callback
    return (hookNamesString, options, callback) ->
      hookNames = hookNamesString.split(" ")
      handleHookName = (hookName, next) ->
        processHook hookName, options, next
      async.each hookNames, handleHookName, callback

  constructor: (@app, @identifier, @models) ->
    @dirname = "#{@app.path}/plugins/#{@identifier}"
    try
      @meta = require "#{@dirname}/package.json"
      {@name, @version} = @meta
    @name ?= @identifier
    try
      _.extend @, require "#{@dirname}"

  initialize: (done) ->
    done()

  migrate: (done) ->
    migrator.runMigration 'up', null, @identifier, done

  modelFilenames: (done) ->
    fs.readdir "#{@dirname}/models", (err, files = []) =>
      filenames = []
      files.forEach (filename) =>
        [ignore, name, ext] = filename.match /^(.*?)(?:\.(js|coffee))?$/
        return if name is 'index' or name.substr(0,1) is '.'
        return unless ext?.length
        filenames.push "#{@dirname}/models/#{name}"
      done null, filenames

  load: (callback) ->
    @once 'load', callback if callback?
    async.series [
      @migrate.bind(this)
      @loadSettings.bind(this)
      @initialize.bind(this)
    ], =>
      @emit 'load'

  loadSettings: (callback) ->
    next = =>
      callback()
    settingName = "plugin.#{@identifier}"
    @models.Setting.find()
    .where(name:settingName)
    .first (err, @setting) =>
      throw err if err
      console.log "GOT SETTING" if @setting
      return next() if @setting
      data =
        name: settingName
        meta:
          settings: {}
      @models.Setting.create data, (err, @setting) =>
        throw err if err
        console.log "CREATED SETTING" if @setting
        return next() if @setting
        throw new Error("Couldn't create settings.")

  hook: (hookName, priority, callback) ->
    if typeof priority is 'function'
      callback = priority
      priority = null
    priority = parseInt(priority, 10)
    priority = 0 unless isFinite(priority)
    @app.pluginHooks[hookName] ?= {}
    @app.pluginHooks[hookName][priority] ?= []
    @app.pluginHooks[hookName][priority].push callback

  get: (setting) ->
    if setting?
      return @setting.meta.settings[setting]
    else
      return _.clone @setting.meta.settings

  set: (values, callback) ->
    settings = @setting.meta.settings ? {}
    for k, v of values
      if v?
        settings[k] = v
      else
        delete settings[k]
    @setting.setMeta {settings}
    callback ?= (err) ->
      console.error err if err
    @setting.save callback

module.exports = Plugin

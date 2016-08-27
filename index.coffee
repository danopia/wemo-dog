Wemo = require 'wemo-client'
wemo = new Wemo

{StatsD} = require 'node-dogstatsd'
statsd = new StatsD 'localhost', 8125

macs = []

discover = ->
  wemo.discover (deviceInfo) ->
    {macAddress} = deviceInfo
    return if macAddress in macs
    macs.push macAddress
    connectTo deviceInfo

setInterval discover, 60 * 1000 # minutely
discover()

connectTo = (deviceInfo) ->
  {deviceType, friendlyName, macAddress} = deviceInfo
  return unless deviceType is 'urn:Belkin:device:insight:1'
  
  friendlyName = process.env.WEMO_NAME_OVERRIDE ? friendlyName
  console.log 'Found Wemo device', friendlyName
  client = wemo.client deviceInfo
  tags = [
    'friendly_name:' + friendlyName
    'mac_address:' + macAddress
  ]
  
  sendLine = (pre, post=[]) ->
    statsd.send_data new Buffer [pre..., '#'+tags.join(','), post...].join '|'
  increment = (counter, amt) ->
    sendLine ["wemo.#{counter}:#{amt}", 'c']

  lastUsageMark = -1
  lastTimeMark = -1

  bin = (bool) ->
    if bool then 1
    else 0

  reportStats = (state, mW, data) ->
    statsd.gauge 'wemo.output.is_enabled', bin(+state > 0), tags
    statsd.gauge 'wemo.output.is_running', bin(+state is 1), tags
    statsd.gauge 'wemo.current_draw.watts', mW / 1000, tags
    
    stateMap = 
      '0': 0 # off
      '8': 1 # idle
      '1': 2 # running
    sendLine ['_sc', 'wemo.output_state', stateMap[state]]

    thisUsageMark = +data.TodayConsumed
    thisTimeMark = +data.OnFor

    # Don't report deltas until we have previous data
    if lastUsageMark isnt -1

      if thisUsageMark > lastUsageMark
        usageDelta = thisUsageMark - lastUsageMark
        console.log friendlyName, 'consumed', usageDelta / 1000 / 60, 'watt-hours'
        increment 'consumed.watt_hours', usageDelta / 1000 / 60
        increment 'consumed.watt_minutes', usageDelta / 1000

      if thisTimeMark > lastTimeMark
        timeDelta = thisTimeMark - lastTimeMark
        console.log friendlyName, 'ran', timeDelta, 'seconds'
        increment 'output.running_seconds', timeDelta
      else # Report inactive time as well
        increment 'output.running_seconds', 0

    lastUsageMark = thisUsageMark
    lastTimeMark = thisTimeMark
    
  checkStats = ->
    client.getInsightParams (err, args...) -> if err
      console.log new Date().toString(), friendlyName,  'Encountered', err
      sendLine ['_sc', 'wemo.reachable', 2], ['m:' + err.message]
    else
      reportStats args...
      sendLine ['_sc', 'wemo.reachable', 0]
  
  setInterval checkStats, 5 * 1000
  checkStats()

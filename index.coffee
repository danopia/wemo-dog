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

setInterval discover, 15 * 1000
discover()

connectTo = (deviceInfo) ->
  {deviceType, friendlyName, macAddress} = deviceInfo
  return unless deviceType is 'urn:Belkin:device:insight:1'
  
  console.log 'Found Wemo device', friendlyName
  client = wemo.client deviceInfo
  tags = [
    'friendly_name:' + friendlyName
    'mac_address:' + macAddress
  ]

  lastUsageMark = -1
  lastTimeMark = -1

  bin = (bool) ->
    if bool then 1
    else 0

  reportStats = (state, mW, data) ->
    statsd.gauge 'wemo.output.is_enabled', bin(+state > 0), tags
    statsd.gauge 'wemo.output.is_running', bin(+state is 1), tags
    statsd.gauge 'wemo.current_draw.watts', mW / 1000, tags

    thisUsageMark = +data.TodayConsumed
    thisTimeMark = +data.OnFor

    # Don't report deltas until we have previous data
    if lastUsageMark isnt -1

      if thisUsageMark > lastUsageMark
        usageDelta = thisUsageMark - lastUsageMark
        console.log friendlyName, 'consumed', usageDelta / 1000 / 60, 'watt horus'
        statsd.update_stats 'wemo.consumed.watt_hours', usageDelta / 1000 / 60, tags
        statsd.update_stats 'wemo.consumed.watt_minutes', usageDelta / 1000, tags

      if thisTimeMark > lastTimeMark
        timeDelta = thisTimeMark - lastTimeMark
        console.log friendlyName, 'ran', timeDelta, 'seconds'
        statsd.update_stats 'wemo.output.running_seconds', timeDelta, tags
      else # Report inactive time as well
        statsd.update_stats 'wemo.output.running_seconds', 0, tags

    lastUsageMark = thisUsageMark
    lastTimeMark = thisTimeMark
    
  checkStats = ->
    client.getInsightParams (err, args...) -> if err
      console.log new Date().toString(), friendlyName,  'Encountered', err
      statsd.send_data new Buffer ['_sc', 'wemo.reachable', 2, '#'+tags.join(','), 'm:'+err.message].join '|'
    else
      reportStats args...
      statsd.send_data new Buffer ['_sc', 'wemo.reachable', 0, '#'+tags.join(',')].join '|'
  
  setInterval checkStats, 5 * 1000
  checkStats()

# Delba Heater

## Installation

1. Create or edit the autoexec.be file with the following line:

```
load('heater_control.be')
```


## Data Model

### Power Usage messages

The heaters are able to ration power usage based on the power usage messages provided by Home Assistant.
These messages have the following format:

```
{ "CurrentPower": integer, "RemainingPower": integer }

```

This provides the current power being consumed by the house in watts, and the power budget
still available for the heaters.


## TODO

 * Improve the doze mode to consider the size of the state table.
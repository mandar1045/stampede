# Changelog

## v0.1.0 (unreleased)

First release.

  * Scenarios with stages, setup data and thresholds
  * Timings with percentiles accurate to 1%, and counters
  * A Phoenix Channels client with heartbeats, replies, broadcasts and both serializers
  * A LiveView client that loads the page, following redirects, joins with its
    tokens and cookies, sends clicks, form changes and submits to the LiveView
    or one of its components, and patches and navigates between LiveViews
  * `mix stampede.run`, which exits with status 1 when a threshold fails

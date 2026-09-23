# Dashboard guide

Use `vw_powerbi_forex_analytics` as the main Power BI table and enable a single-select `currency_pair` slicer.

Recommended layout:

- Header: latest exchange rate, daily return, trend signal, and 20-day volatility cards.
- Main chart: `rate_date` on the axis, `daily_close`, `ma_20`, and `ma_50` as values.
- Risk panel: `price_z_score`, Bollinger bands, and `annualized_volatility_pct`.
- Nigeria panel: table from `vw_nigeria_top10_agrofoods`, showing commodity, NGN price, unit, date, and source.

Palette: mint `#E7F5EF`, deep green `#145A46`, accent green `#16805C`, ink `#18332C`, warning rose `#C93756`. Keep cards compact, use clear labels, and show the NBS publication date beside every agro-food figure.

For incremental refresh, create `RangeStart` and `RangeEnd` as Date/Time parameters, filter `rate_date >= RangeStart` and `rate_date < RangeEnd`, confirm query folding, then archive five years and refresh the last three days.

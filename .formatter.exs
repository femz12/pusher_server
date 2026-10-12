[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  # Plug.Router DSL calls that read better without parentheses
  locals_without_parens: [plug: 1, plug: 2]
]

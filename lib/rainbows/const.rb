# -*- encoding: binary -*-
# :enddoc:
module Rainbows::Const
end
require 'rainbows/version'
module Rainbows::Const
  include Unicorn::Const

  RACK_DEFAULTS = Unicorn::HttpRequest::DEFAULTS.update({
    "SERVER_SOFTWARE" => "Rainbows! #{RAINBOWS_VERSION}",

    # using the Rev model, we'll automatically chunk pipe and socket objects
    # if they're the response body.  Unset by default.
    # "rainbows.autochunk" => false,
  })
end

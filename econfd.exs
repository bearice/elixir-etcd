defmodule EConfd do

end

EConfd.start([
  watch: "/trigger",
  template: "test.eex"
  render_to: "test.conf"
  #check_cmd: "chk_syntax.sh"
  #reload_cmd: "reload.sh"
])

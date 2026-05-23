defmodule Rnnoise.Error do
  @moduledoc "Raised when the rnnoise model cannot be resolved, downloaded, or loaded."
  defexception [:message, :reason]
end

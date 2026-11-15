defmodule NanoKVMGo.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :nano_kvm_go,
      version: @version,
      elixir: "~> 1.15",
      description: description(),
      package: package(),
      compilers: [:elixir_make | Mix.compilers()],
      make_targets: ["all"],
      make_clean: ["clean"],
      make_error_message: make_error_message(),
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      dialyzer: [flags: [:missing_return, :extra_return, :unmatched_returns, :error_handling]]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  def cli do
    [preferred_envs: [docs: :docs, "hex.build": :docs, dialyzer: :test, credo: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp description do
    "The hardware of the Sipeed NanoKVM-Go for Elixir and Nerves: video capture " <>
      "with H.264 and JPEG encoding, audio capture, USB keyboard and mouse, USB mass storage, " <>
      "the LCD, the auxiliary port's expansion lines, and the device's own parts and metrics."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      files: [
        "lib",
        "c_src/*.[ch]",
        "Makefile",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "LICENSE",
        ".formatter.exs"
      ]
    ]
  end

  defp deps do
    [
      {:elixir_make, "~> 0.9", runtime: false},
      {:circuits_gpio, "~> 2.3"},
      {:ex_doc, "~> 0.34", only: :docs, runtime: false},
      {:dialyxir, "~> 1.4", only: :test, runtime: false},
      {:credo, "~> 1.7", only: :test, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      source_ref: "v#{@version}",
      groups_for_modules: [
        "Video and audio": [
          NanoKVMGo.Video,
          NanoKVMGo.Video.Input,
          NanoKVMGo.EDID,
          NanoKVMGo.Audio,
          NanoKVMGo.Microphone
        ],
        "Keyboard and mouse": [NanoKVMGo.HID, NanoKVMGo.HID.Keymap, NanoKVMGo.HID.Report],
        USB: [NanoKVMGo.USB, NanoKVMGo.Storage],
        "LCD, touch panel, button": [
          NanoKVMGo.Display,
          NanoKVMGo.Display.Canvas,
          NanoKVMGo.Backlight,
          NanoKVMGo.Touch,
          NanoKVMGo.Button
        ],
        "The device": [NanoKVMGo.Hardware, NanoKVMGo.Metrics, NanoKVMGo.Expansion]
      ]
    ]
  end

  defp make_error_message do
    """
    Could not build the nano_kvm_go_video port program. It needs a Linux C
    toolchain with the V4L2 headers; Nerves provides one for the NanoKVM-Go.
    """
  end
end

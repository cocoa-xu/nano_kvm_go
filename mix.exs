defmodule NanoKVMGo.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/cocoa-xu/nano_kvm_go"

  def project do
    [
      app: :nano_kvm_go,
      version: @version,
      elixir: "~> 1.20",
      description: description(),
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,
      compilers: [:elixir_make | Mix.compilers()],
      make_targets: ["all"],
      make_clean: ["clean"],
      make_error_message: make_error_message(),
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      dialyzer: [
        plt_add_apps: [:ex_unit],
        flags: [:missing_return, :extra_return, :unmatched_returns, :error_handling]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  def cli do
    [
      preferred_envs: [
        docs: :docs,
        "hex.build": :docs,
        "hex.publish": :docs,
        dialyzer: :test,
        credo: :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp description do
    "The hardware of the Sipeed NanoKVM-Go for Elixir and Nerves: video capture " <>
      "with H.264 and JPEG encoding, audio capture and playback, the LCD, the auxiliary " <>
      "port's expansion lines, the board's USB gadget, and the device's own parts and metrics."
  end

  defp package do
    [
      licenses: ["Apache-2.0", "BSD-2-Clause", "BSD-3-Clause"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "https://hexdocs.pm/nano_kvm_go/changelog.html"
      },
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
      {:muontrap, "~> 2.0"},
      {:nerves_runtime, "~> 0.13", optional: true},
      {:ex_doc, "~> 0.34", only: :docs, runtime: false},
      {:dialyxir, "~> 1.4", only: :test, runtime: false},
      {:credo, "~> 1.7", only: :test, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      source_ref: "v#{@version}",
      groups_for_modules: [
        "Video and audio": [
          NanoKVMGo.Video,
          NanoKVMGo.EDID,
          NanoKVMGo.Audio,
          NanoKVMGo.Microphone
        ],
        "LCD, touch panel, button": [
          NanoKVMGo.Display,
          NanoKVMGo.Display.Canvas,
          NanoKVMGo.Backlight,
          NanoKVMGo.Touch,
          NanoKVMGo.Button
        ],
        "The device": [
          NanoKVMGo.Hardware,
          NanoKVMGo.Metrics,
          NanoKVMGo.CMA,
          NanoKVMGo.Expansion,
          NanoKVMGo.USB
        ]
      ]
    ]
  end

  defp make_error_message do
    """
    Could not build the port programs. They need a Linux C toolchain with
    the kernel's headers; Nerves provides one for the NanoKVM-Go.
    """
  end
end

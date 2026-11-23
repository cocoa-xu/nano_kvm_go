# SPDX-License-Identifier: BSD-2-Clause
defmodule NanoKVMGo.Display.Font do
  @moduledoc false
  # Printable ASCII of Spleen 8x16 (2.1.0), 16 bytes a character, a row a
  # byte, the leftmost pixel the highest bit.
  #
  # Copyright (c) 2018-2024, Frederic Cambus. All rights reserved.
  # Redistribution and use in source and binary forms, with or without
  # modification, are permitted provided that the following conditions are
  # met: redistributions of source code must retain the above copyright
  # notice, this list of conditions and the following disclaimer;
  # redistributions in binary form must reproduce the above copyright notice,
  # this list of conditions and the following disclaimer in the documentation
  # and/or other materials provided with the distribution. THIS SOFTWARE IS
  # PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
  # OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
  # WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
  # DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
  # LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
  # CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
  # SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
  # INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
  # CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
  # ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
  # POSSIBILITY OF SUCH DAMAGE.

  @glyphs Base.decode64!(
            "AAAAAAAAAAAAAAAAAAAAAAAAGBgYGBgYGAAYGAAAAAAAZmZmZgAAAAAAAAAAAAAAAABsbP5sbGxs" <>
              "/mxsAAAAAAAQftDQ0HwWFhYW/BAAAAAAAAZmbAwYGDA2ZmAAAAAAAAA4bGxsOHDazMx6AAAAAAAY" <>
              "GBgYAAAAAAAAAAAAAAAADhgwMGBgYGAwMBgOAAAAAHAYDAwGBgYGDAwYcAAAAAAAAABmPBj/GDxm" <>
              "AAAAAAAAAAAAABgYfhgYAAAAAAAAAAAAAAAAAAAAABgYMAAAAAAAAAAAAAB+AAAAAAAAAAAAAAAA" <>
              "AAAAAAAAGBgAAAAAAAYGDAwYGDAwYGDAwAAAAAAAfMbGzt725sbGfAAAAAAAABg4eFgYGBgYGH4A" <>
              "AAAAAAB8xgYGDBgwYMb+AAAAAAAAfMYGBjwGBgbGfAAAAAAAAMDAzMzMzP4MDAwAAAAAAAD+xsDA" <>
              "/AYGBsZ8AAAAAAAAfMbAwPzGxsbGfAAAAAAAAP7GBgYMGDAwMDAAAAAAAAB8xsbGfMbGxsZ8AAAA" <>
              "AAAAfMbGxsZ+BgbGfAAAAAAAAAAAABgYAAAAGBgAAAAAAAAAAAAYGAAAABgYMAAAAAAABgwYMGBg" <>
              "MBgMBgAAAAAAAAAAAH4AAH4AAAAAAAAAAABgMBgMBgYMGDBgAAAAAAAAfMYGDBgwMAAwMAAAAAAA" <>
              "AAB8wtra2trewHwAAAAAAAB8xsbG/sbGxsbGAAAAAAAA/MbGxvzGxsbG/AAAAAAAAH7AwMDAwMDA" <>
              "wH4AAAAAAAD8xsbGxsbGxsb8AAAAAAAAfsDAwPjAwMDAfgAAAAAAAH7AwMD4wMDAwMAAAAAAAAB+" <>
              "wMDA3sbGxsZ+AAAAAAAAxsbGxv7GxsbGxgAAAAAAAH4YGBgYGBgYGH4AAAAAAAB+GBgYGBgYGBjw" <>
              "AAAAAAAAxsbGzPjMxsbGxgAAAAAAAMDAwMDAwMDAwH4AAAAAAADG7v7WxsbGxsbGAAAAAAAAxsbm" <>
              "5tbWzs7GxgAAAAAAAHzGxsbGxsbGxnwAAAAAAAD8xsbG/MDAwMDAAAAAAAAAfMbGxsbGxtbWfBgM" <>
              "AAAAAPzGxsb8xsbGxsYAAAAAAAB+wMDAfAYGBgb8AAAAAAAA/xgYGBgYGBgYGAAAAAAAAMbGxsbG" <>
              "xsbGxn4AAAAAAADGxsbGxsbGbDgQAAAAAAAAxsbGxsbG1v7uxgAAAAAAAMbGxmw4bMbGxsYAAAAA" <>
              "AADGxsbGfgYGBgb8AAAAAAAA/gYGDBgwYMDA/gAAAAAAPjAwMDAwMDAwMDA+AAAAAMDAYGAwMBgY" <>
              "DAwGBgAAAAB8DAwMDAwMDAwMDHwAAAAAEDhsxgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD+AAAw" <>
              "GAwAAAAAAAAAAAAAAAAAAAAAAHwGfsbGxn4AAAAAAADAwMD8xsbGxsb8AAAAAAAAAAAAfsDAwMDA" <>
              "fgAAAAAAAAYGBn7GxsbGxn4AAAAAAAAAAAB+xsb+wMB+AAAAAAAAHjAwMHwwMDAwMAAAAAAAAAAA" <>
              "AH7GxsbGxnwGBvwAAADAwMD8xsbGxsbGAAAAAAAAGBgAOBgYGBgYHAAAAAAAABgYABgYGBgYGBgY" <>
              "GHAAAADAwMDM2PDw2MzGAAAAAAAAMDAwMDAwMDAwHAAAAAAAAAAAAOzW1tbWxsYAAAAAAAAAAAD8" <>
              "xsbGxsbGAAAAAAAAAAAAfMbGxsbGfAAAAAAAAAAAAPzGxsbGxvzAwMAAAAAAAAB+xsbGxsZ+BgYG" <>
              "AAAAAAAAfsbAwMDAwAAAAAAAAAAAAH7AwHwGBvwAAAAAAAAwMDB8MDAwMDAeAAAAAAAAAAAAxsbG" <>
              "xsbGfgAAAAAAAAAAAMbGxsZsOBAAAAAAAAAAAADGxtbW1tZuAAAAAAAAAAAAxmw4OGzGxgAAAAAA" <>
              "AAAAAMbGxsbGxn4GBvwAAAAAAAD+BgwYMGD+AAAAAAAOGBgYGHBwGBgYGA4AAAAAGBgYGBgYGBgY" <>
              "GBgYAAAAAHAYGBgYDg4YGBgYcAAAAAAAAAAAADJ+TAAAAAAAAAA="
          )

  @width 8
  @height 16

  @runs @glyphs
        |> :binary.bin_to_list()
        |> Enum.map(fn row ->
          for(<<(pixel::1 <- <<row>>)>>, do: pixel)
          |> Enum.with_index()
          |> Enum.chunk_by(fn {pixel, _offset} -> pixel end)
          |> Enum.flat_map(fn
            [{1, offset} | _] = run -> [{offset, length(run)}]
            [{0, _offset} | _] -> []
          end)
        end)
        |> List.to_tuple()

  @spec width() :: 8
  def width, do: @width

  @spec height() :: 16
  def height, do: @height

  @spec runs(char(), 0..15) :: [{0..7, 1..8}]
  def runs(char, row) when char in 32..126, do: elem(@runs, (char - 32) * @height + row)
  def runs(_char, row), do: runs(??, row)
end

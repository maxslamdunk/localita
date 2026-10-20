#!/usr/bin/env ruby

# Writes the iPhone app's Acknowledgements screen data: the license and NOTICE
# text of every package compiled into the app, at the exact revisions in
# Package.resolved, plus the copyright of each bundled math font.
#
# Apache-2.0 and MIT both ask that a binary carry the license and notices of
# the code inside it, and App Store users never see this repository, so the
# app shows them itself (Settings → Generation → Acknowledgements).
#
#   ruby Scripts/generate_acknowledgements.rb           # rewrite the JSON
#   ruby Scripts/generate_acknowledgements.rb --check   # exit 1 if it is stale
#
# Reads the checkouts SwiftPM keeps in .build/checkouts; `swift package
# resolve` creates them. Every package in Package.resolved must be listed in
# LINKED or NOT_LINKED below, so a new dependency fails here until someone
# decides which it is.

require "json"

ROOT = File.expand_path("..", __dir__)
RESOLVED = File.join(ROOT, "Package.resolved")
CHECKOUTS = File.join(ROOT, ".build/checkouts")
OUTPUT = File.join(ROOT, "iOS/TurboFieldfareiOS/Acknowledgements.json")

# Packages whose code is in the iOS binary, with the file names to copy. Taken
# from the modules in a Release-iphoneos build's products folder
# (DerivedData/.../Build/Products/Release-iphoneos/*.swiftmodule, yyjson.o):
# Crypto, EventSource, HuggingFace, Hub, Tokenizers, Jinja, OrderedCollections,
# SwiftMath, yyjson.
LINKED = {
  "eventsource" => %w[LICENSE.md],
  "swift-collections" => %w[LICENSE.txt],
  "swift-crypto" => %w[LICENSE.txt NOTICE.txt],
  "swift-huggingface" => %w[LICENSE],
  "swift-jinja" => %w[LICENSE],
  "swift-transformers" => %w[LICENSE],
  "swiftmath" => %w[LICENSE],
  "yyjson" => %w[LICENSE],
}.freeze

# Resolved, but no module of theirs is in the iOS binary.
NOT_LINKED = {
  "swift-nio" => "the Mac server only",
  "swift-asn1" => "swift-crypto's CryptoExtras, which nothing here uses",
  "swift-atomics" => "swift-nio",
  "swift-system" => "swift-nio",
}.freeze

FONTS_DIR = "Sources/SwiftMath/mathFonts.bundle"
FONT_LICENSES = %w[OFL.txt GUST-FONT-LICENSE.txt].freeze

def license_name(text)
  if text.include?("Apache License") && text.include?("Version 2.0")
    text.include?("Runtime Library Exception") ? "Apache-2.0 with Runtime Library Exception" : "Apache-2.0"
  elsif text.include?("Permission is hereby granted, free of charge")
    "MIT"
  else
    abort "unrecognised license text; add its name to license_name"
  end
end

# The copyright and license strings of an OpenType font, from its `name`
# table: Windows Unicode English records, else Mac Roman ones.
def font_names(path)
  data = File.binread(path)
  count = data[4, 2].unpack1("n")
  record = (0...count).map { |i| data[12 + 16 * i, 16].unpack("a4NNN") }
                      .find { |tag, *| tag == "name" }
  abort "#{path}: no name table" unless record

  base = record[2]
  _, name_count, strings = data[base, 6].unpack("nnn")
  names = {}
  name_count.times do |i|
    platform, encoding, language, id, length, offset = data[base + 6 + 12 * i, 12].unpack("n6")
    raw = data[base + strings + offset, length]
    if platform == 3 && encoding == 1 && language == 0x409
      names[id] = raw.force_encoding("UTF-16BE").encode("UTF-8")
    elsif platform == 1 && encoding == 0 && language == 0
      names[id] ||= raw.force_encoding("MacRoman").encode("UTF-8")
    end
  end
  names
end

def checkout(pin)
  dir = File.join(CHECKOUTS, File.basename(pin.fetch("location"), ".git"))
  abort "missing #{dir}; run `swift package resolve`" unless Dir.exist?(dir)

  head = `git -C #{dir} rev-parse HEAD`.strip
  revision = pin.fetch("state").fetch("revision")
  unless head == revision
    abort "#{dir} is at #{head}, Package.resolved wants #{revision}; run `swift package resolve`"
  end
  dir
end

def read_text(path)
  File.read(path, encoding: "UTF-8").gsub("\r\n", "\n").strip
end

def build
  pins = JSON.parse(File.read(RESOLVED)).fetch("pins").to_h { |pin| [pin.fetch("identity"), pin] }
  unlisted = pins.keys - LINKED.keys - NOT_LINKED.keys
  abort "Package.resolved has #{unlisted.join(', ')}; add to LINKED or NOT_LINKED" unless unlisted.empty?
  missing = (LINKED.keys + NOT_LINKED.keys) - pins.keys
  abort "no longer resolved: #{missing.join(', ')}; remove from LINKED or NOT_LINKED" unless missing.empty?

  this = read_text(File.join(ROOT, "LICENSE"))
  entries = [{
    "name" => "TurboFieldfare",
    "about" => "Localita is derived from TurboFieldfare by drumih and shares its license.",
    "url" => "https://github.com/drumih/turbo-fieldfare",
    "license" => license_name(this),
    "texts" => [{ "title" => "LICENSE", "body" => this }],
  }]

  packages = LINKED.map do |identity, files|
    pin = pins.fetch(identity)
    dir = checkout(pin)
    texts = files.map { |file| { "title" => file, "body" => read_text(File.join(dir, file)) } }
    state = pin.fetch("state")
    {
      "name" => File.basename(pin.fetch("location"), ".git"),
      "version" => state["version"] || "revision #{state.fetch('revision')[0, 7]}",
      "url" => pin.fetch("location").delete_suffix(".git"),
      "license" => license_name(texts.first.fetch("body")),
      "texts" => texts,
    }
  end
  entries += packages.sort_by { |entry| entry.fetch("name").downcase }

  fonts = File.join(checkout(pins.fetch("swiftmath")), FONTS_DIR)
  copyrights = Dir[File.join(fonts, "*.otf")].sort_by(&:downcase).map do |path|
    names = font_names(path)
    copyright = [names[0], names[13]].compact.map(&:strip).find { |s| s.match?(/copy(right|left)|\(c\)|©/i) }
    "#{names.fetch(4)}: #{(copyright || names[13] || names[0]).strip}"
  end
  entries << {
    "name" => "SwiftMath math fonts",
    "about" => "The fonts SwiftMath bundles to typeset math. Each is under the SIL Open Font License 1.1 or the GUST Font License; the copyright lines below are read from the font files.",
    "url" => "#{pins.fetch('swiftmath').fetch('location').delete_suffix('.git')}/tree/main/#{FONTS_DIR}",
    "license" => "OFL-1.1, GUST",
    "notes" => copyrights,
    "texts" => FONT_LICENSES.map { |file| { "title" => file, "body" => read_text(File.join(fonts, file)) } },
  }

  JSON.pretty_generate(entries) + "\n"
end

generated = build
if ARGV.include?("--check")
  current = File.exist?(OUTPUT) ? File.read(OUTPUT) : ""
  if current == generated
    puts "Acknowledgements.json is current"
  else
    warn "Acknowledgements.json is stale; run ruby Scripts/generate_acknowledgements.rb"
    exit 1
  end
else
  File.write(OUTPUT, generated)
  puts "wrote #{OUTPUT.delete_prefix(ROOT + '/')} (#{generated.bytesize} bytes)"
end

#!/usr/bin/env ruby

#
# Requirements: Nokogiri, libarchive-ruby
#     # In Debian, with RVM
#     sudo aptitude install libarchive-dev
#     gem install nokogiri libarchive-ruby
#
# Check for the latest version of Steel Bank Common Lisp by:
# * Access a SourceForge's mirror as a HTTP page
# * Find all available version strings on the page
# * Loop through all versions in descending order:
#   - If there is a Linux AMD64 tarball, download to DOWNLOAD_DESTINATION
#   - If there isn't a Linux AMD64 tarball for that version, proceed the
#     next one
# * Checksum
# * Extract to DOWNLOAD_DESTINATION
# * Install using `INSTALL_ROOT=#{INSTALL_DESTINATION} sh ./install.sh`
# * Copy the core to INSTALL_DESTINATION
# * Check to see if the SBCL_HOME env var is already exists and remind of
#   adding
#
# Note: The code is verbose because I want to make full use of Ruby, not
# calling shell command unless I have no choice.
#
# Debate: Forking is expensive, but it doesn't matter in this case.  Should I
# use external tool instead of Ruby?
#

require 'nokogiri'
require 'open-uri'
require 'net/http'
require 'archive'
require 'fileutils'

DOWNLOAD_DESTINATION = "/m/cmpitg/opt/"
INSTALL_DESTINATION  = File.expand_path "~/opt/sbcl/"

SITE_NAME            = "www.mirrorservice.org"
SITE_PATH            = "/sites/ftp.sourceforge.net/pub/sourceforge/s/sb/sbcl/sbcl/"
SBCL_DOWNLOAD_URL    = "http://#{SITE_NAME}/#{SITE_PATH}"
SBCL_TARBALL_FORMAT  = "sbcl-%{version}-x86-64-linux-binary.tar.bz2"

def main
  versions         = get_version_strings
  current_version  = get_current_version
  latest_version   = get_latest_version_string versions

  if latest_version == ""
    puts "There's some problem with the site, please check the URLs in #{__file__}"
    return
  end

  puts "Current version: #{current_version}"
  puts "Latest version: #{latest_version}"

  puts
  if current_version != latest_version
    puts "Start downloading latest version"
    download_latest latest_version
    extract_tarball latest_version
  else
    puts "You already have the latest version! :-)"
  end
end

# Public: Remind user of setting up SBCL_HOME and PATH
def remind_setting_up_env
  puts
  if ENV["SBCL_HOME"] == "" || !system("which sbcl >/dev/null 2>&1")
    puts "Be sure to set something similar to:"
    puts "    SBCL_HOME=#{INSTALL_DESTINATION}"
    puts "    PATH=#{INSTALL_DESTINATION}/bin"
    puts "in your shell's rc file.  You might want to consider aliasing sbcl" \
         "with GNU Readline and adding it to your shell's rc:"
    puts "    alias sbcl='rlwrap sbcl'"
  else
    puts "Found SBCL_HOME and sbcl in PATH. Your environment seems to be" \
         "setup correctly. :-)"
  end
end

# Public: Install SBCL by running:
#
# INSTALL_ROOT=#{INSTALL_DESTINATION} sh ./install.sh
#
# Then copy output/scbl.core from SBCL dir to INSTALL_DESTINATION
def install_sbcl(version)
  puts
  puts "Installing to #{INSTALL_DESTINATION}"

  file_path = DOWNLOAD_DESTINATION + build_file_name(version)
  extracted_dir = file_path.sub('-binary.tar.bz2', '')

  # # SBCL_HOME conflicts with INSTALL_ROOT (for some odd reason)
  # sbcl_home           = ENV["SBCL_HOME"]
  # ENV['INSTALL_ROOT'] = INSTALL_DESTINATION

  # Dir.chdir extracted_dir
  # `unset SBCL_HOME && sh ./install.sh`
  # FileUtils.cp 'output/sbcl.core', INSTALL_DESTINATION
  # ENV['SBCL_HOME']    = sbcl_home

  sbcl_home           = ENV["SBCL_HOME"]

  # Update symlink
  `cd #{sbcl_home}; sudo ln -s #{extracted_dir} #{sbcl_home}`
end

# Public: Extract the tarball in DOWNLOAD_DESTINATION
def extract_tarball(version)
  file_path = DOWNLOAD_DESTINATION + build_file_name(version)

  puts
  puts "Extracting #{file_path}"

  Dir.chdir DOWNLOAD_DESTINATION
  Archive.new(file_path).extract
end

def get_current_version
  `sbcl --version`.split[1]
end

def get_latest_version_string(versions)
  versions.each { |version|
    version = version[0..-2]
    filename = build_file_name version
    file_url = build_download_url version

    puts "Checking version #{version}"
    puts "    Filename: #{filename}"
    puts "    File URL: #{file_url}"
    puts "    Exists?: #{url_exists? file_url}"

    return version if url_exists? file_url
  }
  ""
end

def build_download_url(version)
  filename = build_file_name version
  SBCL_DOWNLOAD_URL + version + "/" + filename
end

def build_file_name(version)
  SBCL_TARBALL_FORMAT % { :version => version }
end

def url_exists?(url)
  url = URI.parse url
  return_code = Net::HTTP.new(url.host, url.port).request_head(url.path).code
  nil != ((/3../ =~ return_code) || (/2../ =~ return_code))
end

# Public: Download latest version to DOWNLOAD_DESTINATION
def download_latest(version)
  filename = build_file_name version
  file_url_path = SITE_PATH + version + "/" + filename

  # puts "Filename: #{filename}"
  # puts "File URL: #{build_download_url version}"

  download_and_display(SITE_NAME,
                       file_url_path,
                       "#{DOWNLOAD_DESTINATION}/#{filename}")
end

# Public: Get all version strings from SBCL download URL
def get_version_strings
  doc = Nokogiri::HTML open(SBCL_DOWNLOAD_URL)
  version_strings = doc.css("img[alt='[DIR]'] + a")[1..-1].map {|e| e.content}.reverse
end

class Fixnum
  def format_number
    self.to_s.reverse.gsub(/...(?=.)/,'\&,').reverse
  end
end

def download(server, path, destination = "/tmp/somefile")
  Thread.new do
    thread          = Thread.current
    thread[:done]   = 0

    Net::HTTP.start(server) do |http|
      open(destination, 'wb') do |file|
        http.request_get(path) do |resp|
          thread[:total] = resp['Content-Length'].to_i

          if thread[:total] == 0
            puts "File not found!"
            thread.terminate
          end

          puts "File size: #{thread[:total].format_number} B"

          resp.read_body do |segment|
            file.write segment

            thread[:done] += segment.length
            thread[:progress] = thread[:done].quo(thread[:total]) * 100
          end
        end
      end
    end
  end
end

# Public: Download a file from a server, return true if the file exists and
# false vice-versa.
def download_and_display(server, path, destination = "/tmp/somefile")
  thread = download server, path, destination
  puts "Prepare to download: #{server}/#{path}"

  while !thread.join(1)
    progress = thread[:progress].to_f
    print "Downloading: \t%{done}/%{total} \t\t%{progress}\r" % {
      :done      => thread[:done].format_number,
      :total     => thread[:total].format_number,
      :progress  => "%0.2f%%" % progress
    } if progress != 0
  end

  puts
  puts "%{total}/%{total}\t\t\t100%" % {
    :total     => thread[:total].format_number,
  }
  puts "Done!"
  thread[:total] != 0
end

#####
## Main
#

main

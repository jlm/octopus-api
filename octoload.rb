#!/usr/bin/env ruby
####
# Copyright 2020-2020 John Messenger
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
####

require 'rubygems'
require 'slop'
require 'open-uri'
require 'date'
require 'json'
require 'rest-client'
require 'yaml'
require 'nokogiri'
require 'logger'
require 'csv'

require './oct_api'

class Time
  def bod
    arr = self.to_a
    arr[0] = 0
    arr[1] = 0
    arr[2] = 0
    Time.local *arr
  end
end

begin
  opts = Slop.parse do |o|
    o.string '-s', '--secrets', 'secrets YAML file name', default: 'secrets.yml'
    o.bool   '-d', '--debug', 'debug mode'
    o.bool   '-p', '--slackpost', 'post alerts to Slack for new items'
    o.string '--postcode', 'installation postcode'
    o.string '--emps', 'list electricity meter points for a given MPAN'
    o.bool   '-c', '--consumption', 'fetch consumption data in some format'
    o.bool   '-a', '--all', 'don\'t stop at first already-existing item'
    o.string '-f', '--from', 'start at this datetime'
    o.string '-t', '--to', 'stop at this datetime'
    o.string '--at', 'select products available at a particular date'
    o.string '--csv', 'write output to this file in CSV format'
    o.bool   '--products', 'retrieve product information from the Octopus API'
    o.string '-m', '--match', 'select products matching the given string in their display name'
    o.string '--product', 'retrieve details of a single product'
    o.on '--help' do
      STDERR.puts o
      exit
    end
  end
  config = YAML.load(File.read(opts[:secrets]))

  # Set up logging
  $DEBUG = opts.debug?
  $logger = Logger.new(STDERR)
  $logger.level = Logger::INFO
  $logger.level = Logger::DEBUG if $DEBUG
  #
  # Log in to the 802.1 Maintenance Database
  #
  if $DEBUG
    RestClient.proxy = "http://localhost:8888"
    $logger.debug("Using HTTP proxy #{RestClient.proxy}")
  end

  #
  # If we are posting to Slack, open the Slack webhook
  #
  if opts[:slackpost]
    slack = RestClient::Resource.new(config['slack_webhook'])
  end

  from = opts[:from] ? Time.parse(opts[:from]).iso8601 : nil
  to = opts[:to] ? Time.parse(opts[:to]).iso8601 : nil
  at = opts[:at] ? Time.parse(opts[:at]).iso8601 : nil

  $logger.debug("from: #{from.to_s}; to: #{to.to_s}; at: #{at.to_s}")

  octo = OctAPI.new(config['key'], $logger)
  octo.postcode = opts[:postcode]     # This also sets the PES name

  #####
  #####     ELECTRICITY METER POINTS
  #####
  if opts[:emps]
    emps = octo.emps(opts[:emps] + '/')
    if emps
      puts "mpan: #{emps['mpan']}: GSP: #{emps['gsp']}, profile class: #{emps['profile_class']}"
    end
  end

  #####
  #####     PRODUCTS
  #####
  if opts[:products]
    params = at ? { available_at: at } : nil
    products = octo.products(params)
    products.select! { |p| p['display_name'].match(Regexp.new(opts[:match])) } if opts[:match]
    products.each do |product|
      puts "#{product['code']}: #{product['display_name']}"

    end
    twit = 36
  end

  if opts[:product]
    params = at ? { tariffs_active_at: at } : nil
    p = octo.product(opts[:product], params)
    puts "Product #{opts[:product]} tariffs active at #{p.tariffs_active_at}"
    puts "Matching tariffs:"
  end

  #####
  #####     CONSUMPTION
  #####
  if opts[:consumption]
    if opts[:csv]
      csv = CSV.open(opts[:csv], 'wb')
    else
      csv = nil
    end

    cons = octo.consumption(config['mpan'], config['serial'], 25000, from, to)
    twit = 35
    results = cons['results']
    ######
    # Output the consumption data to a CSV file, if selected
    # The header row says "Date," and then 00:00,00:30,01:00,01:30 etc.
    ######
    row = ['Date']
    48.times do |col|
      row << Time.parse(results[col]['interval_start']).getlocal(0).strftime('%H:%M')
    end
    csv << row if csv
    ######
    # Each line in the table starts with YYYY-MM-DD and then real numbers giving consumption in kWh per slot
    ######
    (0..(results.length / 48 - 1)).each { |rowno|
      row = []
      row << Time.parse(results[48 * rowno]['interval_start']).getlocal(0).strftime("%Y-%m-%d")
      48.times do |col|
        row << results[48 * rowno + col]['consumption'].to_f
      end
      csv << row if csv
    }

    csv.close if csv
  end
end

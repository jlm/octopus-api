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
require 'active_support/core_ext/numeric/time'

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
END_TIME = Time.parse('2116-02-19')

def mktime_from(timestr)
  Time.parse(timestr).localtime(0)
rescue => e
  $logger.debug("mktime_from: parsing '#{timestr.inspect}' gives #{e.to_s}")
  Time.at(0)
end

def mktime_to(timestr)
  if timestr.nil?
    END_TIME
  else
    Time.parse(timestr).localtime(0)
  end
rescue => e
  $logger.warn("mktime_to: parsing '#{timestr.inspect}' gives #{e.to_s}")
  END_TIME
end

def print_tariff_summary(ts)
  tt = OctAPI.tariff_type_name(ts.tariff_type)
  case ts.tariff_type
  when :sr_elec, :sr_gas
      price = "Standard unit rate: #{ts.sur_incvat} p/kWh"
  when :dr_elec
    price = "Day unit rate: #{ts.dur_incvat} p/kWh, Night unit rate: #{ts.nur_incvat} p/kWh"
  else
    raise ArgumentError, 'unknown tariff type'
  end
  puts "  + #{ts.tariff_code}: #{tt} #{ts.payment_model}: Standing charge: #{ts.sc_incvat} p/day, #{price}"
  ts.sc&.reverse_each  { |rate| print_tariff_charge(rate, 'Standard charge', 'p/day') }
  ts.sur&.reverse_each { |rate| print_tariff_charge(rate, 'Standard unit rate') }
  ts.dur&.reverse_each { |rate| print_tariff_charge(rate, 'Day unit rate') }
  ts.nur&.reverse_each { |rate| print_tariff_charge(rate, 'Night unit rate') }
end

def print_product(code, product)
  puts "Product #{code} \"#{product.display_name}\" tariffs active at #{product.tariffs_active_at}"
  #puts "Matching tariffs:"
  if product.tariffs.empty?
    puts "  + No applicable tariffs"
    return
  end
  if product.region
    product.tariffs[product.region].each(&method(:print_tariff_summary))
  else
    product.tariffs.each do |_region, tslist|
      tslist.each(&method(:print_tariff_summary))
    end
  end
end

def print_tariff_charge(rate, rate_name = '', rate_unit = 'p/kWh')
  puts "    #{rate['valid_from'].to_s} to #{rate['valid_to'].to_s}: #{rate_name} #{rate['value_inc_vat']} #{rate_unit}"
end

# Output the consumption data to a CSV file, if selected
# The header row says "Date," and then 00:00,00:30,01:00,01:30 etc.
# @param [CSV] csv already-opened CSV object to write to
# @param [Array<Hash{String=>String,Float}>] results Array of consumption slots
# @return [void]
def output_consumption_as_csv(csv, results)
  row = ['Date']
  48.times do |col|
    row << Time.parse(results[col]['interval_start']).getlocal(0).strftime('%H:%M')
  end
  csv << row
  ######
  # Each line in the table starts with YYYY-MM-DD and then real numbers giving consumption in kWh per slot
  ######
  (0..(results.length / 48 - 1)).each { |rowno|
    row = []
    row << Time.parse(results[48 * rowno]['interval_start']).getlocal(0).strftime("%Y-%m-%d")
    48.times do |col|
      row << results[48 * rowno + col]['consumption'].to_f
    end
    csv << row
  }
  csv.close
end

def process_bucket(bucket, bucket_no, iter, start, sc)
  $logger.info("#{start.to_s}: bucket #{bucket_no} full after #{iter} iterations; sc: #{sc}; cost: #{bucket}")
end

# Find a rate applicable during an interval, in an array of intervals
# @param [Array<Hash>] ratelist Array of (valid_from, valid_to, value) tuples
# @param [Object] start start time of interval to search for
# @param [Object] finish finish time of interval to search for
# @return [Float] the rate found
def find_rate(ratelist, start, finish)
  ratelist.each do |tslot|
    valid_from = mktime_from(tslot['valid_from'])
    valid_to = mktime_to(tslot['valid_to'])
    if start.between?(valid_from, valid_to)
      # $logger.debug("cons slot start #{start.to_s}: found rate slot #{valid_from.to_s} to #{valid_to.to_s}")
      if finish.between?(valid_from, valid_to)
        # $logger.debug("...and it includes the finish time too: #{finish.to_s}")
        return tslot['value_inc_vat'].to_f
      else
        $logger.fatal("finish time of consumption time slot was after end of tariff validity slot")
        abort('fatal error')
      end
    end
  end
  $logger.fatal("no matching rate found")
  abort('fatal error')
end

###
###   MAIN PROGRAM
###
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
    o.string '--compare', 'compare specified product with matching available products based on consumption'
    o.string '--period', 'comparison period, such as 2.weeks'
    o.bool '--export', 'include Export products'
    o.on '--help' do
      STDERR.puts o
      exit
    end
  end
  #noinspection RubyResolve
  config = YAML.load(File.read(opts[:secrets]))

  # Set up logging
  $_debug = opts.debug?
  $logger = Logger.new(STDERR)
  $logger.level = Logger::INFO
  $logger.level = Logger::DEBUG if $_debug
  #
  # Set up debugging through Charles Proxy
  #
  rest_client_options = {}
  if $_debug
    RestClient.proxy = "http://localhost:8888"
    $logger.debug("Using HTTP proxy #{RestClient.proxy}")
    rest_client_options = { verify_ssl: OpenSSL::SSL::VERIFY_NONE }
  end

  #
  # If we are posting to Slack, open the Slack webhook
  #
=begin
  if opts[:slackpost]
    slack = RestClient::Resource.new(config['slack_webhook'])
  end
=end

  from_time = opts[:from] ? mktime_from(opts[:from]) : nil
  from = opts[:from] ? from_time.iso8601 : nil
  to_time = opts[:to] ? mktime_to(opts[:to]) : nil
  to = opts[:to] ? to_time.iso8601 : nil
  at = opts[:at] ? Time.parse(opts[:at]).iso8601 : nil
  bucket_length = eval(config['period'] || '1.week')
  bucket_length = eval(opts[:period]) if opts[:period]

  $logger.debug("from: #{from.to_s}; to: #{to.to_s}; at: #{at.to_s}")

  octo = OctAPI.new(config['key'], $logger, rest_client_options)
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
  #####     CONSUMPTION
  #####
  if opts[:consumption] || opts[:compare]
    csv = opts[:csv] ? CSV.open(opts[:csv], 'wb') : nil
    params = {}
    params[:period_from] = from if from
    params[:period_to] = to if to
    consumption = octo.consumption(config['mpan'], config['serial'], params)
    output_consumption_as_csv(csv, consumption) if csv
  end

  #####
  #####     PRODUCTS
  #####
  if opts[:compare]
    pd_params = {}
    pd_params[:tariffs_active_at] = at if at
    pd_params[:period_from] = from if from
    pd_params[:period_to] = to if to
    comparator = octo.product(opts[:compare], pd_params)
    puts 'Comparator tariff:'
    print_product(opts[:compare], comparator)
  end

  products = []
  if opts[:products] || opts[:compare]
    params = at ? { available_at: at } : {}
    prods = octo.products(params)
    prods.select! { |p| p['display_name'].match(Regexp.new(opts[:match])) } if opts[:match]
    prods.select! { |p| p['direction'] == 'IMPORT' } unless opts[:export]
    prods.each do |prod|
      pd_params = {}
      pd_params[:tariffs_active_at] = at if at
      pd_params[:period_from] = from if from
      pd_params[:period_to] = to if to

      # Local variables:
      # @type [Time] from app-level period start
      # @type [Time] to app-level period end
      # @type [Time] start consumption slot start
      # @type [Time] finish consumption slot end
      # @type [Time] valid_from tariff slot start
      # @type [Time] valid_to tariff slot end
      # @type [Product] product
      products << product = octo.product(prod['code'], pd_params)
      $logger.warn('specify a postcode to allow retrieval of tariff charges') if product.region.nil?
      print_product(prod['code'], product) if opts[:products]
      if opts[:compare]
        unless product.tariffs[product.region]
          $logger.debug("skipping product #{product.product_code} as it has no tariffs for region #{product.region}")
          next
        end
        product.tariffs[product.region].each do |tariff|
          if tariff.tariff_type != :sr_elec
            $logger.debug("skipping tariff #{tariff.tariff_code} of type #{tariff.tariff_type.to_s}")
            next
          end
          $logger.info("Comparing to tariff #{tariff.tariff_code}...")
          bucket_marker = 0
          bucket = standing_charge = 0
          day_marker = 0
          consumption.each do |slot|
            start = mktime_from(slot['interval_start'])
            finish = mktime_to(slot['interval_end'])
            usage = slot['consumption'].to_f
            bucket_number = (start - from_time).to_i / bucket_length
            day_number = (start - from_time).to_i / 1.day.to_i
            if day_number > day_marker
              standing_charge += (day_number - day_marker) * find_rate(tariff.sc, start, finish)
              day_marker = day_number
            end

            # End of period:
            if bucket_number > bucket_marker
              process_bucket(bucket, bucket_number, (start - from_time).to_i / (finish - start), start, standing_charge)
              bucket = 0
              bucket_marker = bucket_number
              standing_charge = 0
            end
            bucket += usage * find_rate(tariff.sur, start, finish)
          end
        end
      end
    end
  end

  if opts[:product]
    pd_params = {}
    pd_params[:tariffs_active_at] = at if at
    pd_params[:period_from] = from if from
    pd_params[:period_to] = to if to
    p = octo.product(opts[:product], pd_params)
    print_product(opts[:product], p)
  end
end

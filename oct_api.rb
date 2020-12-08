#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
####

require 'rubygems'
require 'rest-client'
require 'json'

class OctAPI
  attr_reader :postcode
  attr_accessor :logger

  # @param [String] key Octopus API key
  # @param [Logger] logger A previously-created Logger object
  # @param [Hash] options Use this to pass `verify_ssl: OpenSSL::SSL::VERIFY_NONE`
  # @return [OctAPI] A newly-created OctAPI instance
  def initialize(key, logger = nil, options = {})
    @key = key
    @logger = logger
    @api = RestClient::Resource.new('https://api.octopus.energy/v1/', options.merge({ user: @key, password: '', }))
  end

   ######
  # Set the postcode, and derive the grid supply point list from it.
  ######
  def postcode=(postcode)
    @postcode = postcode
    gsps = postcode && gsps(postcode)
    if gsps && (gsps['count'] == 1)
      @pes_name = gsps['results'].first['group_id']
      #noinspection RubyNilAnalysis
      @logger.info("postcode <#{postcode}>: grid supply point PES name: #{@pes_name}") if @logger
    else
      @logger.warn("postcode <#{postcode}>: grid supply point not uniquely found") if @logger
    end
  end

  #noinspection SpellCheckingInspection
  def gsps(postcode)
    params = { postcode: postcode }
    octofetch('industry/grid-supply-points/', params)
  end

  #noinspection SpellCheckingInspection
  def emps(mpan)
    octofetch("electricity-meter-points/%s" % mpan)
  end

  def consumption(mpan, serial, page_size = 48, period_from = nil, period_to = nil, _group_by = nil)
    params = { :page_size => page_size.to_s, :order_by => 'period' }
    params[:period_from] = period_from if period_from
    params[:period_to] = period_to if period_to
    octofetch("electricity-meter-points/#{mpan}/meters/#{serial}/consumption/", params)
  end

  def products(params = {})
    octofetch_array("products/", params)
  end

  TARIFF_TYPES = {sr_elec: "Electricity", dr_elec: "Economy-7", sr_gas: "Gas" }
  ######
  # A class method to give the tariff type name of a tariff class
  def self.tariff_type_name(tariff_type)
    TARIFF_TYPES[tariff_type]
  end

  def tariff_charges(prodcode, tariffcode, tarifftype, params={})
    case tarifftype
    when :sr_elec
      sc =  octofetch_array("products/#{prodcode}/electricity-tariffs/#{tariffcode}/standing-charges/", params)
      rates = octofetch_array("products/#{prodcode}/electricity-tariffs/#{tariffcode}/standard-unit-rates/", params)
    when :dr_elec
      sc =  octofetch_array("products/#{prodcode}/electricity-tariffs/#{tariffcode}/standing-charges/", params)
      rates = octofetch_array("products/#{prodcode}/electricity-tariffs/#{tariffcode}/day-unit-rates/", params)
      rates += octofetch_array("products/#{prodcode}/electricity-tariffs/#{tariffcode}/night-unit-rates/", params)
    when :sr_gas
      sc =  octofetch_array("products/#{prodcode}/gas-tariffs/#{tariffcode}/standing-charges/", params)
      rates = octofetch_array("products/#{prodcode}/gas-tariffs/#{tariffcode}/standard-unit-rates/", params)
    else
      raise ArgumentError, 'tarriftype must be :sr_elec, :dr_elec or :sr_gas'
    end
    [sc, rates]
  end

  Product = Struct.new(:tariffs_active_at, :is_variable, :available_from, :available_to, :is_business, :is_green, :is_prepay,
                       :is_restricted, :is_tracker, :full_name, :display_name, :term, :brand, :description,
                       :region, :sr_elec_tariffs, :dr_elec_tariffs, :sr_gas_tariffs, :tariffs, keyword_init: true)
  TariffSummary = Struct.new(:tariff_code, :tariff_type, :payment_model, :sc_excvat, :sc_incvat, :sur_excvat, :sur_incvat,
                             :dur_excvat, :dur_incvat, :nur_excvat, :nur_incvat,
                             keyword_init: true)

  ######
  # Retrieve details of a product.
  ######
  def product(code, params = nil)
    prod = octofetch("products/#{code}/", params)
    result = Product.new(
      tariffs_active_at: Time.parse(prod['tariffs_active_at']).getlocal(0),
      full_name: prod['full_name'],
      display_name: prod['display_name'],
      description: prod['description'],
      is_green: prod['is_green'],
      is_tracker: prod['is_tracker'],
      is_prepay: prod['is_prepay'],
      is_business: prod['is_business'],
      is_restricted: prod['is_restricted'],
      term: prod['term'],
      available_from: prod['available_from'] && Time.parse(prod['available_from']).getlocal(0),
      available_to: prod['available_to'] && Time.parse(prod['available_to']).getlocal(0),
      brand: prod['brand'],
      is_variable: prod['is_variable']
    )
    if @pes_name
      result.region = @pes_name
    end
    result.tariffs = prod['single_register_electricity_tariffs']&.each_with_object({}) do |(region,pmg), memohash|
      memohash[region] ||= []
      memohash[region] += make_array_of_tariffs(pmg, :sr_elec)
    end
    result.tariffs = prod['dual_register_electricity_tariffs']&.each_with_object(result.tariffs) do |(region,pmg), memohash|
      memohash[region] ||= []
      memohash[region] += make_array_of_tariffs(pmg, :dr_elec)
    end
    result.tariffs = prod['single_register_gas_tariffs']&.each_with_object(result.tariffs) do |(region,pmg), memohash|
      memohash[region] ||= []
      memohash[region] += make_array_of_tariffs(pmg, :sr_gas)
    end
    result
  end

  private

  def octofetch(spec, params = {})
    begin
      option_hash = {:accept => :json }
      option_hash[:params] = params if params
      resp = @api[spec].get option_hash
    rescue => e
      abort("octopus-api: #{spec}: " + e.message)
    end
    JSON.parse(resp)
  end

  def octofetch_array(spec, params = {})
    result = []
    myparams = params.dup
    begin
      response = octofetch(spec, myparams)
      result += response['results']
      myparams[:page] = response['next'] && response['next'].split('page=')[1]
    end while myparams[:page]
    result
  end

  # Translate a payment method group returned from the Octopus API into an array of TariffSummary objects.
  # The payment method and tariff type are squashed into the TariffSummary objects.
  #
  # @param [Hash<String, Hash>] pmg A hash whose keys are payment method names (e.g., 'direct_debit_monthly')
  #     and whose values are hashes representing tariff summaries.
  # @param [:sr_elec,:dr_elec,:sr_gas] tariff_type The tariff type.  (see TARIFF_TYPES)
  # @return [Array<TariffSummary>] An array of struct TariffSummary objects
  def make_array_of_tariffs(pmg, tariff_type)
    tariff_list = []
    pmg.each do |payment_model, tariff_summary|
      ts = TariffSummary.new(
        tariff_code: tariff_summary['code'],
        tariff_type: tariff_type,
        payment_model: payment_model,
        sc_excvat: tariff_summary['standing_charge_exc_vat'],
        sc_incvat: tariff_summary['standing_charge_inc_vat'],
        sur_excvat: tariff_summary['standard_unit_rate_exc_vat'],
        sur_incvat: tariff_summary['standard_unit_rate_inc_vat'],
        dur_excvat: tariff_summary['day_unit_rate_exc_vat'],
        dur_incvat: tariff_summary['day_unit_rate_inc_vat'],
        nur_excvat: tariff_summary['night_unit_rate_exc_vat'],
        nur_incvat: tariff_summary['night_unit_rate_inc_vat']
      )
      tariff_list << ts
    end
    tariff_list
  end

end

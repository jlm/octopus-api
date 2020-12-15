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

  # Sets up a client instance ready to query the Octopus Energy API (https://developer.octopus.energy/docs/api/).
  # @param [String] key Octopus API key
  # @param [Logger] logger A previously-created Logger object
  # @param [Hash] options Use this to pass +verify_ssl: OpenSSL::SSL::VERIFY_NONE+ for debugging with https://www.charlesproxy.com/
  # @return [OctAPI] A newly-created OctAPI instance
  def initialize(key, logger = nil, options = {})
    @key = key
    @logger = logger
    @api = RestClient::Resource.new('https://api.octopus.energy/v1/', options.merge({ user: @key, password: '', }))
  end

  # Set the postcode, and derive the grid supply point list from it.
  # @param [String] postcode Postcode of the supply point, used to select available products and localise tariff charges
  # @return [String] the same postcode
  def postcode=(postcode)
    @postcode = postcode
    gsps = postcode && gsps(postcode)
    if gsps && (gsps.length == 1)
      @pes_name = gsps.first
      @logger.info("postcode <#{postcode}>: grid supply point PES name: #{@pes_name}") if @logger
    else
      @logger.warn("postcode <#{postcode}>: grid supply point not uniquely found") if @logger
    end
    postcode
  end

  # Fetch the Grid Supply Point (aka PES name) for a supplied postcode, from the API. If no postcode is specified, fetch all of them,
  # @param [String] postcode
  # @return [Array<String>,nil] an array of PES names, e.g., +["_F"]+
  def gsps(postcode)
    r = octofetch_array('industry/grid-supply-points/', { postcode: postcode })
    r && r.map{|p| p['group_id']}
  end

  # Fetch the Grid Supply Point (aka PES name) and profile class of a given meter point.
  # @param [String] mpan the Meter Point Administration Number (MPAN, aka Supply Number or S-Number)
  # @return [Hash{String=>(String,Integer)}] A hash with three elements:
  #   :gsp the Grid Supply Point name (e.g. "_F")
  #   :mpan the MPAN as supplied
  #   :profile_class whoever knows what this is?  It's an integer, such as 1
  def emps(mpan)
    octofetch("electricity-meter-points/%s" % mpan)
  end

  def consumption(mpan, serial, opts = {})
    params = { :page_size => (7*48).to_s, :order_by => 'period' }
    params.merge!(opts)
    octofetch_array("electricity-meter-points/#{mpan}/meters/#{serial}/consumption/", params)
  end

  def products(params = {})
    octofetch_array("products/", params)
  end

  TARIFF_TYPES = [ :sr_elec, :dr_elec, :sr_gas ]
  TARIFF_TYPE_NAMES = { sr_elec: "Electricity", dr_elec: "Economy-7", sr_gas: "Gas" }
  ######
  # A class method to give the tariff type name of a tariff type
  # @param [TARIFF_TYPES] tariff_type
  # @return [String] the name of the tariff type
  def self.tariff_type_name(tariff_type)
    TARIFF_TYPE_NAMES[tariff_type]
  end

  def tariff_charges(prodcode, tariffcode, tarifftype, params={})
    night_rates = nil
    case tarifftype
    when :sr_elec
      sc =  octofetch_array("products/#{prodcode}/electricity-tariffs/#{tariffcode}/standing-charges/", params)
      rates = octofetch_array("products/#{prodcode}/electricity-tariffs/#{tariffcode}/standard-unit-rates/", params)
    when :dr_elec
      sc =  octofetch_array("products/#{prodcode}/electricity-tariffs/#{tariffcode}/standing-charges/", params)
      rates = octofetch_array("products/#{prodcode}/electricity-tariffs/#{tariffcode}/day-unit-rates/", params)
      night_rates = octofetch_array("products/#{prodcode}/electricity-tariffs/#{tariffcode}/night-unit-rates/", params)
    when :sr_gas
      sc =  octofetch_array("products/#{prodcode}/gas-tariffs/#{tariffcode}/standing-charges/", params)
      rates = octofetch_array("products/#{prodcode}/gas-tariffs/#{tariffcode}/standard-unit-rates/", params)
    else
      raise ArgumentError, 'tarriftype must be :sr_elec, :dr_elec or :sr_gas'
    end
    [sc, rates, night_rates]
  end

  Product = Struct.new(:product_code, :tariffs_active_at, :is_variable, :available_from, :available_to, :is_business, :is_green, :is_prepay,
                       :is_restricted, :is_tracker, :full_name, :display_name, :term, :brand, :description,
                       :region, :sr_elec_tariffs, :dr_elec_tariffs, :sr_gas_tariffs, :tariffs, keyword_init: true) do
    def to_s(verbose = nil)
      str = "Product #{self.product_code} \"#{self.display_name}\" tariffs active at #{self.tariffs_active_at}\n"
      #puts "Matching tariffs:"
      if self.tariffs.empty?
        str << "  + No applicable tariffs\n"
        return
      end
      if verbose
        if self.region
          self.tariffs[self.region].each { |ts| str << ts.to_s(verbose) }
        else
          self.tariffs.each do |_region, tslist|
            tslist.each { |ts| str << ts.to_s(verbose) }
          end
        end
      end
      str
    end
  end

  TariffSummary = Struct.new(:tariff_code, :tariff_type, :payment_model, :sc_excvat, :sc_incvat, :sur_excvat, :sur_incvat,
                             :dur_excvat, :dur_incvat, :nur_excvat, :nur_incvat, :sc, :sur, :dur, :nur,
                             keyword_init: true) do
    def to_s(verbose = nil)
      tt = OctAPI.tariff_type_name(self.tariff_type)
      case self.tariff_type
      when :sr_elec, :sr_gas
        price = "Standard unit rate: #{self.sur_incvat} p/kWh"
      when :dr_elec
        price = "Day unit rate: #{self.dur_incvat} p/kWh, Night unit rate: #{self.nur_incvat} p/kWh"
      else
        raise ArgumentError, 'unknown tariff type'
      end
      str = "  + #{self.tariff_code}: #{tt} #{self.payment_model}: Standing charge: #{self.sc_incvat} p/day, #{price}"
      if verbose
        self.sc&.reverse_each  { |rate| str << stringify_tariff_charge(rate, 'Standard charge', 'p/day') }
        self.sur&.reverse_each { |rate| str << stringify_tariff_charge(rate, 'Standard unit rate') }
        self.dur&.reverse_each { |rate| str << stringify_tariff_charge(rate, 'Day unit rate') }
        self.nur&.reverse_each { |rate| str << stringify_tariff_charge(rate, 'Night unit rate') }
      end
      str
    end

    private

    def stringify_tariff_charge(rate, rate_name, rate_unit = '')
      "    #{rate['valid_from'].to_s} to #{rate['valid_to'].to_s}: #{rate_name} #{rate['value_inc_vat']} #{rate_unit}\n"
    end
  end

  # Retrieve details of a product. If a period is specified with :period_from, then attach tariff histories for each tariff.
  # @param [String] code the Octopus product code
  # @param [Hash, nil] params parameters for the API call
  # @option params [Time] :available_at select products available at the time specified. nil means now.
  # @option params [Time] :period_from include tariff rate information from the time specified
  # @option params [Time] :period_to include tariff rate information up to the time specified (must also specify :period_from)
  # @return [Product] A new Product structure containing the retrieved product details
  def product(code, params = {})
    prod = octofetch("products/#{code}/", params)
    product = Product.new(
      product_code: code,
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
    # The PES name specified via the postcode (if any) is stored in the Product.  This is used
    # as a flag to allow retrieval of tariff charge history, because retrieving it for all
    # regions might be a lot of data.
    if @pes_name
      product.region = @pes_name
    end
    # For each tariff type, for each region (designated by a PES name typically _A to _P derived from a postcode), extract
    # the list of tariff summaries returned in the "product" API call, and combine them into a hash indexed by region.
    # The tariff summaries are tagged with their tariff type, instead of being structured by it.
    product.tariffs = prod['single_register_electricity_tariffs']&.each_with_object({}) do |(region,pmg), memohash|
      memohash[region] ||= []
      memohash[region] += make_array_of_tariffs(pmg, :sr_elec)
    end
    product.tariffs = prod['dual_register_electricity_tariffs']&.each_with_object(product.tariffs) do |(region,pmg), memohash|
      memohash[region] ||= []
      memohash[region] += make_array_of_tariffs(pmg, :dr_elec)
    end
    product.tariffs = prod['single_register_gas_tariffs']&.each_with_object(product.tariffs) do |(region,pmg), memohash|
      memohash[region] ||= []
      memohash[region] += make_array_of_tariffs(pmg, :sr_gas)
    end
    # If a period was specified using :period_from, and a region has been selected,
    # then retrieve and include a tariff charge "history" (which could extend into the future too).
    if params[:period_from] && product.region && !product.tariffs.empty? && product.tariffs[product.region]
      product.tariffs[product.region].each do |ts|
        scs, rates, night_rates = tariff_charges(product.product_code, ts.tariff_code, ts.tariff_type,
                                                 { period_from: params[:period_from], period_to: params[:period_to] })
        ts.sc = scs
        case ts.tariff_type
        when :sr_elec
          ts.sur = rates
        when :dr_elec
          ts.dur = rates
          ts.nur = night_rates
        when :sr_gas
          ts.sur = rates
        else
          raise ArgumentError, "unknown tariff_type #{ts.tariff_type.to_s} for tariff #{ts.tariff_code}"
        end
      end
    end
    product
  end

  private

  def octofetch(spec, params = {})
    begin
      option_hash = {:accept => :json }
      option_hash[:params] = params if params
      resp = @api[spec].get option_hash
    rescue => e
      @logger.fatal("octopus-api: #{spec}: " + e.message) if @logger
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
      myparams[:page] = response['next'] && URI.decode_www_form(URI.parse(response['next']).query).to_h['page']
    end while myparams[:page]
    result
  end

  # Translate a payment method group returned from the Octopus API into an array of TariffSummary objects.
  # The payment method and tariff type are squashed into the TariffSummary objects.
  #
  # @param [Hash{String=>Hash}>] pmg A hash whose keys are payment method names (e.g., 'direct_debit_monthly')
  #     and whose values are hashes representing tariff summaries.
  # @param [:sr_elec,:dr_elec,:sr_gas] tariff_type The tariff type.  (see TARIFF_TYPE_NAMES)
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

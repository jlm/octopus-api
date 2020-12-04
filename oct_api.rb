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

  def initialize(key, logger = nil)
    @key = key
    @logger = logger
    if $DEBUG
      @api = RestClient::Resource.new('https://api.octopus.energy/v1/', user: @key, password: '', verify_ssl: OpenSSL::SSL::VERIFY_NONE)
    else
      @api = RestClient::Resource.new('https://api.octopus.energy/v1/', user: @key, password: '')
    end
  end

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

  ######
  # Set the postcode, and derive the grid supply point list from it.
  ######
  def postcode=(postcode)
    @postcode = postcode
    gsps = postcode && gsps(postcode)
    if gsps && (gsps['count'] == 1)
      @pes_name = gsps['results'].first['group_id']
      @logger.info("postcode <#{postcode}>: grid supply point PES name: #{@pes_name}") if @logger
    else
      @logger.warn("postcode <#{postcode}>: grid supply point not uniquely found") if @logger
    end
  end

  def gsps(postcode)
    params = { postcode: postcode }
    octofetch('industry/grid-supply-points/', params)
  end

  def emps(mpan)
    octofetch("electricity-meter-points/%s" % mpan)
  end

  def consumption(mpan, serial, page_size = 48, period_from = nil, period_to = nil, group_by = nil)
    params = { :page_size => page_size.to_s, :order_by => 'period' }
    params[:period_from] = period_from if period_from
    params[:period_to] = period_to if period_to
    octofetch("electricity-meter-points/#{mpan}/meters/#{serial}/consumption/", params)
  end

  def products(params = {})
    result = []
    begin
      response = octofetch("products/", params)
      result += response['results']
      params[:page] = response['next'] && response['next'].split('page=')[1]
    end while params[:page]
    result
  end

  def tariff_charges(prodcode, tariffcode, params={})
    sc =  octofetch("products/#{prodcode}/electricity-tariffs/#{tariffcode}/standing-charges/", params)
    sur = octofetch("products/#{prodcode}/electricity-tariffs/#{tariffcode}/standard-unit-rates/", params)
    { sc: sc, sur: sur}
  end

  Product = Struct.new(:tariffs_active_at, :is_variable, :available_from, :available_to, :is_business, :is_green, :is_prepay,
                       :is_restricted, :is_tracker, :full_name, :display_name, :term, :brand, :description,
                       :region, :sr_elec_tariffs, :dr_elec_tariffs, :sr_gas_tariffs, keyword_init: true)
  TariffSummary = Struct.new(:tariff_code, :payment_model, :sur_excvat, :sur_incvat, :sc_excvat, :sc_incvat,
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
    result.sr_elec_tariffs = {}
    prod['single_register_electricity_tariffs'].each do |region, pmg|
      tariff_list = []
      pmg.each do |payment_model, tariff_summary|
        ts = TariffSummary.new(
          tariff_code: tariff_summary['code'],
          payment_model: payment_model,
          sur_excvat: tariff_summary['standard_unit_rate_exc_vat'],
          sur_incvat: tariff_summary['standard_unit_rate_inc_vat'],
          sc_excvat: tariff_summary['standing_charge_exc_vat'],
          sc_incvat: tariff_summary['standing_charge_inc_vat']
        )
        tariff_list << ts
      end
      result.sr_elec_tariffs[region] = tariff_list
    end
    result
  end
end

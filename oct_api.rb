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
    if gsps['count'] == 1
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

  ######
  # Retrieve details of a product.  I wanted this method to return an object containing the details, but I don't
  # know how to do this properly.  Currently, it's implemented by deriving a class from OctAPI and creating an instance
  # of it to hold the data.  My worry is that this creates too much overhead, including a new RestClient instance for
  # each product query.
  ######
  def product(code, params = nil)
    OctAPI::Product.new(@key, code, params)
  end
end

class OctAPI::Product < OctAPI
  attr_reader :tariffs_active_at, :is_variable, :available_from, :available_to, :is_business, :is_green, :is_prepay,
              :is_restricted, :is_tracker, :full_name, :display_name, :term, :brand

  def initialize(key, code, params = nil)
    super(key)
    @code = code
    prod = octofetch("products/#{code}/", params)
    @tariffs_active_at = Time.parse(prod['tariffs_active_at']).getlocal(0)
    @full_name = prod['full_name']
    @display_name = prod['display_name']
    @description = prod['description']
    @is_variable = prod['is_variable']
    @is_green = prod['is_green']
    @is_tracker = prod['is_tracker']
    @is_prepay = prod['is_prepay']
    @is_business = prod['is_business']
    @is_restricted = prod['is_restricted']
    @term = prod['term']
    @available_from = prod['available_from'] && Time.parse(prod['available_from']).getlocal(0)
    @available_to = prod['available_to'] && Time.parse(prod['available_to']).getlocal(0)
    @brand = prod['brand']
    @is_variable = prod['is_variable']
  end
end

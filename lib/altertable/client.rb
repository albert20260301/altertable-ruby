# frozen_string_literal: true

require "httpx"
require "json"
require "time"
require_relative "errors"

module Altertable
  class Client
    DEFAULT_BASE_URL = "https://api.altertable.ai"
    DEFAULT_CONNECT_TIMEOUT = 5
    DEFAULT_READ_TIMEOUT = 60
    DEFAULT_ENVIRONMENT = "production"

    RESERVED_USER_IDS = %w[
      anonymous_id anonymous distinct_id distinctid false guest
      id not_authenticated true undefined user_id user
      visitor_id visitor
    ].freeze

    RESERVED_USER_IDS_CASE_SENSITIVE = ["[object Object]", "0", "NaN", "none", "None", "null"].freeze

    def initialize(api_key, options = {})
      raise ConfigurationError, "API Key is required" if api_key.nil? || api_key.empty?

      @api_key = api_key
      @base_url = options[:base_url] || DEFAULT_BASE_URL
      @environment = options[:environment] || DEFAULT_ENVIRONMENT
      @connect_timeout = options[:connect_timeout] || DEFAULT_CONNECT_TIMEOUT
      @read_timeout = options[:request_timeout] || DEFAULT_READ_TIMEOUT # keeping request_timeout for backward compat if any, but mapping to read
      @release = options[:release]
      @debug = options[:debug] || false
      @on_error = options[:on_error]

      # Initialize HTTPX client with timeouts and keep-alive (default)
      @http = HTTPX.with(
        timeout: {
          connect: @connect_timeout,
          read: @read_timeout
        },
        origin: @base_url
      )
    end

    def track(event, distinct_id, properties = {})
      validate_user_id!(distinct_id)

      payload = {
        timestamp: Time.now.utc.iso8601(3),
        event: event,
        environment: @environment,
        distinct_id: distinct_id,
        properties: {
          "$lib": "altertable-ruby",
          "$lib_version": Altertable::VERSION
        }.merge(properties)
      }
      payload[:properties]["$release"] = @release if @release

      post("/track", payload)
    end

    def identify(user_id, traits = {})
      validate_user_id!(user_id)

      payload = {
        timestamp: Time.now.utc.iso8601(3),
        environment: @environment,
        distinct_id: user_id,
        traits: traits
      }

      post("/identify", payload)
    end

    def alias(new_user_id, previous_id)
      validate_user_id!(new_user_id)

      payload = {
        timestamp: Time.now.utc.iso8601(3),
        environment: @environment,
        distinct_id: previous_id,
        new_user_id: new_user_id
      }

      post("/alias", payload)
    end

    private

    def validate_user_id!(user_id)
      return if user_id.nil?

      id_str = user_id.to_s
      if RESERVED_USER_IDS.include?(id_str.downcase) || RESERVED_USER_IDS_CASE_SENSITIVE.include?(id_str)
        raise ArgumentError, "Reserved User ID: #{user_id}"
      end
    end

    def post(path, payload)
      headers = {
        "X-API-Key" => @api_key,
        "Content-Type" => "application/json"
      }
      
      begin
        response = @http.post(path, json: payload, headers: headers)
        handle_response(response)
      rescue StandardError => e
        handle_error(e)
      end
    end

    def handle_response(res)
      # httpx response can be an Error response (connection error etc)
      if res.is_a?(HTTPX::ErrorResponse)
        raise NetworkError.new("HTTPX Error: #{res.error.message}", res.error)
      end

      case res.status
      when 200..299
        JSON.parse(res.body.to_s) rescue {}
      when 422
        error_data = JSON.parse(res.body.to_s) rescue {}
        raise ApiError.new("Unprocessable Entity: #{error_data["message"]}", res.status, error_data)
      else
        raise ApiError.new("HTTP Error: #{res.status}", res.status)
      end
    end

    def handle_error(error)
      wrapped_error = if error.is_a?(AltertableError)
                        error
                      elsif error.is_a?(HTTPX::TimeoutError)
                        NetworkError.new("Timeout: #{error.message}", error)
                      elsif error.is_a?(HTTPX::Error)
                        NetworkError.new("Connection Error: #{error.message}", error)
                      else
                        AltertableError.new(error.message, error)
                      end

      @on_error&.call(wrapped_error)
      raise wrapped_error
    end
  end
end

module Solve360
  module Item
    
    def self.included(model)
      model.extend ClassMethods
      model.send(:include, HTTParty)
      model.instance_variable_set(:@field_mapping, {})
    end
    
    # Base Item fields
    attr_accessor :id, :name, :typeid, :created, :updated, :viewed, :ownership, :flagged
    
    # Base item collections
    attr_accessor :fields, :related_items, :related_items_to_add
    
    def initialize(attributes = {})
      attributes.symbolize_keys!
      
      self.fields = {}
      self.related_items = []
      self.related_items_to_add = []
      
      [:fields, :related_items].each do |collection|
        self.send("#{collection}=", attributes[collection]) if attributes[collection]
        attributes.delete collection
      end

      attributes.each do |key, value|
        self.send("#{key}=", value)
      end
    end
    
    # @see Base::map_human_attributes
    def map_human_fields
      self.class.map_human_fields(self.fields)
    end
    
    # Save the attributes for the current record to the CRM
    #
    # If the record is new it will be created on the CRM
    # 
    # @return [Hash] response values from API
    def save
      response = []
      
      if self.ownership.blank?
        self.ownership = Solve360::Config.config.default_ownership
      end
      
      if new_record?
        response = self.class.request(:post, "/#{self.class.resource_name}", to_request)
        
        if !response["response"]["errors"]
          self.id = response["response"]["item"]["id"]
        end
      else
        response = self.class.request(:put, "/#{self.class.resource_name}/#{id}", to_request)
      end
      
      if response["response"]["errors"]
        message = response["response"]["errors"].map {|k,v| "#{k}: #{v}" }.join("\n")
        raise Solve360::SaveFailure, message
      else
        related_items.concat(related_items_to_add)

        response
      end

    end
    
    def new_record?
      self.id == nil
    end
    
    def to_request
      xml = "<request>"
      
      xml << map_human_fields.collect {|key, value| "<#{key}>#{CGI.escapeHTML(value.to_s)}</#{key}>"}.join("")
      
      if related_items_to_add.size > 0
        xml << "<relateditems>"
        
        related_items_to_add.each do |related_item|
          xml << %Q{<add><relatedto><id>#{related_item["id"]}</id></relatedto></add>}
        end
        
        xml << "</relateditems>"
      end
      
      xml << "<ownership>#{ownership}</ownership>"
      xml << "</request>"

      p xml

      xml
    end
    
    def add_related_item(item)
      related_items_to_add << item
    end
    
    module ClassMethods
    
      # Map human map_human_fields to API fields
      # 
      # @param [Hash] human mapped fields
      # @example
      #   map_attributes("First Name" => "Steve", "Description" => "Web Developer")
      #   => {:firstname => "Steve", :custom12345 => "Web Developer"}
      # 
      # @return [Hash] API mapped attributes
      #
      def map_human_fields(fields)
        mapped_fields = {}

        field_mapping.each do |human, api|
          mapped_fields[api] = fields[human] if !fields[human].blank?
        end

        mapped_fields
      end
      
      # As ::map_api_fields but API -> human
      #
      # @param [Hash] API mapped attributes
      # @example
      #   map_attributes(:firstname => "Steve", :custom12345 => "Web Developer")
      #   => {"First Name" => "Steve", "Description" => "Web Developer"}
      #
      # @return [Hash] human mapped attributes
      def map_api_fields(fields)
        fields.stringify_keys!
        
        mapped_fields = {}

        field_mapping.each do |human, api|
          if fields[api].present? && fields[api]['__content__'].present?
            mapped_fields[human] = fields[api]['__content__']
          end
        end
        
        mapped_fields
      end
      
      # Create a record in the API
      #
      # @param [Hash] field => value as configured in Item::fields
      def create(fields, options = {})
        new_record = self.new(fields)
        new_record.save
        new_record
      end

      def search(search_by, value)
        find_all(:filtermode => search_by, :filtervalue => value)
      end
      
      # Find records
      # 
      # @param [Integer, Symbol] id of the record on the CRM or :all
      def find(id, query = nil)
        if id == :all
          find_all(query)
        else
          find_one(id, query)
        end
      end
      
      # Find a single record
      # 
      # @param [Integer] id of the record on the CRM
      def find_one(id, query = nil)
        response = request(:get, "/#{resource_name}/#{id}", query)
        construct_record_from_singular(response)
      end
      
      # Find all records
      def find_all(query = nil)
        response = request(:get, "/#{resource_name}/", "<request><layout>1</layout></request>", query)
        construct_record_from_collection(response)
      end
      
      # Send an HTTP request
      # 
      # @param [Symbol, String] :get, :post, :put or :delete
      # @param [String] url of the resource 
      # @param [String, nil] optional string to send in request body
      def request(verb, uri, body = "", query = nil)
        send(verb, HTTParty.normalize_base_uri(Solve360::Config.config.url) + uri,
            :headers => {"Content-Type" => "application/xml", "Accepts" => "application/json"},
            :body => body,
            :query => query,
            :basic_auth => {:username => Solve360::Config.config.username, :password => Solve360::Config.config.token})
      end
      
      def construct_record_from_singular(response)
        item = response["response"]["item"]
        item.symbolize_keys!
        
        item[:fields] = map_api_fields(item[:fields])
      
        record = new(item)
        
        if response["response"]["relateditems"]
          related_items = response["response"]["relateditems"]["relatedto"]
        
          if related_items.kind_of?(Array)
            record.related_items.concat(related_items)
          else
            record.related_items = [related_items]
          end
        end
        
        record
      end
      
      def construct_record_from_collection(response)
        response["response"].collect do |item|  
          item = item[1]
          if item.respond_to?(:keys)
            attributes = {}
            attributes[:id] = item["id"]
          
            attributes[:fields] = map_api_fields(item)

            record = new(attributes)
          end
        end.compact
      end
      
      def resource_name
        self.name.to_s.demodulize.underscore.pluralize
      end

      def map_fields(&block)        
        @field_mapping.merge! yield
      end
      
      def field_mapping
        @field_mapping
      end
    end
  end
end
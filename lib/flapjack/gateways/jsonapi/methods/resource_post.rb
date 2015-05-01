#!/usr/bin/env ruby

require 'sinatra/base'

module Flapjack
  module Gateways
    class JSONAPI < Sinatra::Base
      module Methods
        module ResourcePost

          def self.registered(app)
            app.helpers Flapjack::Gateways::JSONAPI::Helpers::Headers
            app.helpers Flapjack::Gateways::JSONAPI::Helpers::Miscellaneous
            app.helpers Flapjack::Gateways::JSONAPI::Helpers::Resources

            Flapjack::Gateways::JSONAPI::RESOURCE_CLASSES.each do |resource_class|
              if resource_class.jsonapi_methods.include?(:post)
                resource = resource_class.jsonapi_type.pluralize.downcase

                app.class_eval do
                  single = resource.singularize

                  model_type = resource_class.name.demodulize
                  model_type_data = "jsonapi_data_#{model_type}".to_sym
                  model_type_create_data = "jsonapi_data_#{model_type}Create".to_sym

                  # TODO how to include plural for same route?

                  swagger_path "/#{resource}" do
                    operation :post do
                      key :description, "Create a #{single}"
                      key :operationId, "create_#{single}"
                      key :consumes, [JSONAPI_MEDIA_TYPE]
                      key :produces, [Flapjack::Gateways::JSONAPI.media_type_produced]
                      parameter do
                        key :name, :body
                        key :in, :body
                        key :description, "#{single} to create"
                        key :required, true
                        schema do
                          key :"$ref", model_type_create_data
                        end
                      end
                      response 200 do
                        key :description, "#{single} creation response"
                        schema do
                          key :'$ref', model_type_data
                        end
                      end
                      # response :default do
                      #   key :description, 'unexpected error'
                      #   schema do
                      #     key :'$ref', :ErrorModel
                      #   end
                      # end
                    end
                  end

                end

                app.post "/#{resource}" do
                  status 201

                  resources_data, unwrap = wrapped_params

                  singular_links, multiple_links = resource_class.association_klasses

                  attributes = (resource_class.respond_to?(:jsonapi_attributes) ?
                    resource_class.jsonapi_attributes[:post] : nil) || []

                  validate_data(resources_data, :attributes => attributes,
                    :singular_links => singular_links.keys,
                    :multiple_links => multiple_links.keys,
                    :klass => resource_class)

                  resources = nil

                  id_field = resource_class.respond_to?(:jsonapi_id) ? resource_class.jsonapi_id : nil
                  idf      = id_field || :id

                  data_ids = resources_data.reject {|d| d[idf.to_s].nil? }.
                                            map    {|i| i[idf.to_s].to_s }

                  assoc_klasses = singular_links.values.inject([]) {|memo, slv|
                    memo << slv[:data]
                    memo += slv[:related]
                    memo
                  } | multiple_links.values.inject([]) {|memo, mlv|
                    memo << mlv[:data]
                    memo += mlv[:related]
                    memo
                  }

                  attribute_types = resource_class.attribute_types

                  jsonapi_type = resource_class.jsonapi_type

                  resource_class.lock(*assoc_klasses) do
                    unless data_ids.empty?
                      conflicted_ids = resource_class.intersect(idf => data_ids).ids
                      halt(err(409, "#{resource_class.name.split('::').last.pluralize} already exist with the following #{idf}s: " +
                               conflicted_ids.join(', '))) unless conflicted_ids.empty?
                    end
                    links_by_resource = resources_data.each_with_object({}) do |rd, memo|
                      record_data = normalise_json_data(attribute_types, rd)
                      type = record_data.delete(:type)
                      halt(err(409, "Resource missing data type")) if type.nil?
                      halt(err(409, "Resource data type '#{type}' does not match endpoint '#{jsonapi_type}'")) unless jsonapi_type.eql?(type)
                      record_data[:id] = record_data[id_field] unless id_field.nil?
                      r = resource_class.new(record_data)
                      halt(err(403, "Validation failed, " + r.errors.full_messages.join(', '))) if r.invalid?
                      memo[r] = rd['links']
                    end

                    # get linked objects, fail before save if we don't find them
                    resource_links = links_by_resource.each_with_object({}) do |(r, links), memo|
                      next if links.nil?

                      singular_links.each_pair do |assoc, assoc_klass|
                        next unless links.has_key?(assoc.to_s)
                        memo[r.object_id] ||= {}
                        memo[r.object_id][assoc.to_s] = assoc_klass[:data].find_by_id!(links[assoc.to_s]['linkage']['id'])
                      end

                      multiple_links.each_pair do |assoc, assoc_klass|
                        next unless links.has_key?(assoc.to_s)
                        memo[r.object_id] ||= {}
                        memo[r.object_id][assoc.to_s] = assoc_klass[:data].find_by_ids!(*(links[assoc.to_s]['linkage'].map {|l| l['id']}))
                      end
                    end

                    links_by_resource.keys.each do |r|
                      r.save
                      rl = resource_links[r.object_id]
                      next if rl.nil?
                      rl.each_pair do |assoc, value|
                        case value
                        when Array
                          r.send(assoc.to_sym).add(*value)
                        else
                          r.send("#{assoc}=".to_sym, value)
                        end
                      end
                    end
                    resources = links_by_resource.keys
                  end

                  resource_ids = resources.map(&:id)

                  response.headers['Location'] = "#{request.base_url}/#{resource}/#{resource_ids.join(',')}"

                  data, _ = as_jsonapi(resource_class, jsonapi_type, resource,
                                       resources, resource_ids,
                                       :unwrap => unwrap)

                  Flapjack.dump_json(:data => data)


                end
              end

            end
          end
        end
      end
    end
  end
end

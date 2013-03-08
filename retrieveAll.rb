#!/usr/bin/env ruby

require 'rubygems'
require 'bundler'
Bundler.require(:default) # Require default set of gems.

#detailTypes = %w{ApexClass ApexComponent ApexPage ApexTrigger CustomApplication CustomObject CustomTab Layout Profile Queue RemoteSiteSetting StaticResource Workflow}

#itemsToReview = %w{CustomObjectTranslation CustomSite HomePageLayout PermissionSet ApexClass Role}

# TODO: Add support for Folder-based metadata. Looks quite complex, so I'll forget it for now. http://www.salesforce.com/us/developer/docs/api_meta/Content/meta_folder.htm

class MetadataMirror

    def initialize(metadata_dir = Dir.pwd)
        metadata_dir = Dir.pwd if metadata_dir.nil?
        # Class' defininitive properties.
        @METADATA_WORKING_DIRECTORY = metadata_dir
        # Define some constants.
        @TYPE_CACHE_FILE_NAME = "typeCache.yaml"
        @TYPE_MEMBERS_CACHE_FILE_NAME = "typeMembersCache.yaml"
        @METAFORCE_CONFIG_FILE_NAME = ".metaforce.yml"

        @client = create_client
    end

    def create_client
        Metaforce.configuration.log = false

        # TODO: Figure out UX for choosing target org.
        target_org_name = "production"
        puts "TargetOrg='#{target_org_name}'"
        config_path = File.join(File.expand_path(@METADATA_WORKING_DIRECTORY), @METAFORCE_CONFIG_FILE_NAME)
        puts "ConfigPath='#{config_path}'"

        # Pull org credentials from a YAML file for now.
        config = YAML.load(File.read(config_path))
        # {"production"=>{"username"=>"coolcat24@domain.com", "password"=>"som3p4ss", "security_token"=>"A23bG523dad"}, "developer"=>...}

        #if target_org_name == "production"
        if (true)
            config_username = config[target_org_name]["username"]
            config_password = config[target_org_name]["password"]
            config_security_token = config[target_org_name]["security_token"]
        end
        puts "Using '#{target_org_name}' credentials: username=#{config_username}, password=#{config_password}, security_token=#{config_security_token}"

        @client = Metaforce.new :username => config_username, :password => config_password, :security_token => config_security_token
    end



    def fetch_all_types(refresh_cache = false)

        # Use cache by default.
        if File.exists?(@TYPE_CACHE_FILE_NAME) and refresh_cache == false
            puts "Using cached types..."
            types_hashie = YAML.load(File.read(@TYPE_CACHE_FILE_NAME))
            types_hashie
        end

        # Refresh metadata types from the SF org.
        @client ||= create_client
        types_hashie = @client.describe.metadata_objects.sort { |x,y| x.xml_name <=> y.xml_name }

        # Cache results for next time.
        File.open(@TYPE_CACHE_FILE_NAME, 'w') { |f| f.write(YAML.dump(types_hashie)) }

        return types_hashie
    end

    def append_members_to_types_hashie(types_hashie = {}, refresh_cache = false)

        type_to_members_hash = {}

        # Use cache by default.
        if File.exists?(@TYPE_MEMBERS_CACHE_FILE_NAME) and refresh_cache == false
            puts "Using cached members..."
            type_to_members_hash = YAML.load(File.read(@TYPE_MEMBERS_CACHE_FILE_NAME))
            return type_to_members_hash
        end

        # Refresh metadata members from the SF org.
        @client ||= createClient

        # Request members for each type.
        types_hashie.each do |type_desc|

            begin
                type_members_desc = @client.list_metadata(type_desc.xml_name)
            rescue StandardError => err
                ap "caught exception on #{type_desc.xml_name}: #{err}"
                type_members_desc = {}
            end

            #puts "sorting members=#{type_members_desc}"
            type_members_desc_sorted = type_members_desc.sort do |x,y|
                result = 0
                if x.respond_to?("full_name")
                    result = x.full_name.downcase <=> y.full_name.downcase
                end
                result
            end

            type_to_members_hash[type_desc] = type_members_desc_sorted

        end

        # Cache results for next time.
        File.open(@TYPE_MEMBERS_CACHE_FILE_NAME, 'w') { |f| f.write(YAML.dump(type_to_members_hash)) }

        return type_to_members_hash
    end

    def puts_type_member_hashie(type_to_members_hash = {})

        return if type_to_members_hash.nil?

        type_to_members_hash.each do |type, members|
            puts "#{type.xml_name}"
            members.each do |member|
                puts "- #{member.full_name}" if member.respond_to?(:full_name)
            end
        end
    end

    def convert_hashie_to_manifest_hash(types_to_members_hashie)

        return if types_to_members_hashie.nil?
        types_to_members_manifest_hash = {}

        # Convert the typeToMembersHash from a Hashie
        #   to a format that is suitable to give to Manifest.
        types_to_members_hashie.each_pair do |key, value|
            underscore_key = key.xml_name.underscore
            should_debug ||= underscore_key == 'folder'
            puts "key=#{underscore_key}, value=#{value}" if should_debug
            component_parsing_strategy = nil

            #puts value.class# Should be array, because is list of components.
            component_container_class = value[0].class.name if value[0].nil? == false
            #puts "class=#{component_container_class} and:#{component_container_class.class}"
            if component_container_class == "Hashie::Mash"
                component_parsing_strategy = :from_hashie_strategy
            end
            if component_parsing_strategy.nil?
                component_parsing_strategy = :from_array_strategy
            end
            puts "strategy=#{component_parsing_strategy}"

            component_array = []
            if component_parsing_strategy == :from_array_strategy
                puts "has assoc" if should_debug
                component_name_pair = value.assoc("full_name")
                #puts "found name pair: #{component_name_pair}" if should_debug
                component_name = component_name_pair[1] if component_name_pair.nil? == false
                #puts "found name: #{component_name}" if should_debug
                component_array = [] << component_name
            end
            if component_parsing_strategy == :from_hashie_strategy
                puts "has map" if should_debug
                component_array = value.map do |x|
                    #puts x if should_debug
                    x.full_name if x.respond_to?("full_name")
                end unless value.nil?
                #puts "component_array=#{component_array}" if should_debug
            end
            #puts "valArray=#{component_array}"

            puts "adding to #{underscore_key}: #{component_array}" if should_debug
            types_to_members_manifest_hash[underscore_key] = component_array
        end

        types_to_members_manifest_hash
    end

    # Simple wrapper to write a package file.
    def write_package_xml(type_to_members_manifest_hash)
        return if type_to_members_manifest_hash.nil?

        # Assuming parameter is properly formatted for the Manifest object.
        manifest = Metaforce::Manifest.new(type_to_members_manifest_hash)
        manifest_data = manifest.to_package

        File.open("package.xml", 'w') { |f| f.write(manifest.to_xml) } if manifest.respond_to? :parse

    end

    # Convenience method to write a package file from the Hashie object, which is used
    #   inside the MetadataMirror class.
    def write_package_xml_from_hashie(type_to_members_hash = {})
        type_to_members_manifest_hash = convert_hashie_to_manifest_hash(type_to_members_hash)

        #ap "Converted hashie to manifest:#{type_to_members_manifest_hash}"
        manifest = Metaforce::Manifest.new(type_to_members_manifest_hash)

        write_package_xml(manifest)
    end

    def retrieve_type_components(type_to_component_manifest_hash)
        return if type_to_component_manifest_hash.nil?
        manifest = Metaforce::Manifest.new(type_to_component_manifest_hash)
        @client.retrieve_unpackaged(manifest)
            .extract_to('./tmp')
            .perform

    end

end








# Now we can use the helpful functions.

mirror = MetadataMirror.new

#mirror.retrieve_type_components({:report => ['MyReport1']})
# Maybe we will have to build a different retrieve function for folder-based metadata. These require both metadata and data records.

#types_hashie = mirror.fetch_all_types
#ap types_hashie

#types_to_members_hashie = mirror.append_members_to_types_hashie(types_hashie)
#ap types_to_members_hashie

#mirror.write_package_xml_from_hashie(types_to_members_hashie)



#types_hashie = fetch_all_types

#types_to_members_hashie = append_members_to_types_hashie(types_hashie)

#puts_type_member_hashie(types_to_members_hashie)

#type_to_members_manifest_hash = convert_hashie_to_manifest_hash(types_to_members_hashie)

#write_package_xml(type_to_members_manifest_hash)

#write_package_xml_from_hashie(types_to_members_hashie)




# Now that we can make a full manifest of the SF org,
#   let's pull down the entire org's metadata.

#manifest = Metaforce::Manifest.new(type_to_members_manifest_hash)

#client = create_client
#client.retrieve_unpackaged(manifest)
#    .on_complete { |job| puts "Retrieve Completed: #{job.id}." }
#    .on_error { |job| puts "Retrieve Failed: #{job.id}." }
#    .on_poll { |job| puts "...polling... #{job.inspect}" }
#    .extract_to(METADATA_WORKING_DIRECTORY)
#    .perform





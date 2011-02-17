module AutoCompleteJquery      
  
  def self.included(base)
    base.extend(ClassMethods)
  end

  #
  # Example:
  #
  #   # Controller
  #   class BlogController < ApplicationController
  #     auto_complete_for :post, :title
  #   end
  #
  #   # View
  #   <%= text_field_with_auto_complete :post, title %>
  #
  # By default, auto_complete_for limits the results to 10 entries,
  # and sorts by the given field.
  # 
  # auto_complete_for takes a third parameter, an options hash to
  # the find method used to search for the records:
  #
  #   auto_complete_for :post, :title, :limit => 15, :order => 'created_at DESC'
  #
  # auto_complete_for allows you to pass multiple attributes if you want to return a full name for example
  # NOTE: this will not work with jquery.autocomplete using the option mustMatch
  #   auto_complete_for :user, [:first_name, :last_name]
  #     AND you can also pass a delimiter if you want, it defaults to a " " (space)
  #   auto_complete_for :user, [:first_name, :last_name], :delimiter => ","
  # 
  # For help on defining text input fields with autocompletion, 
  # see ActionView::Helpers::JavaScriptHelper.
  #
  # For more on jQuery auto-complete, see the docs for the jQuery autocomplete 
  # plugin used in conjunction with this plugin:
  # * http://www.dyve.net/jquery/?autocomplete
  #
  # Option hash:
  #
  # :collection_instance_variable
  #
  # pass in the name of an instance variable w/o the '@' to bypass
  # SQL and provide autocomplete from a collection.  Currently, this
  # only works for single methods not an array of methods.  
  #
  # example, pull data from @tags, no SQL used:
  # auto_complete_for :tag, :name, :collection_instance_variable => :tags
  #
  # :associations
  #
  # pass hash where 'key' is 'name of association' and 'value' is separate attribute or array of association attributes
  # This option works only when used ActiveRecord.
  #
  # Example,
  #
  # class Post
  #   belongs_to :author
  # end
  #
  # class Author
  #   has_many :posts
  # end
  #
  # class PostsController
  #   auto_complete_for :post, :title, :associations => {:author => :name}
  #   #or
  #   auto_complete_for :post, :title, :associations => {:author => [:first_name, :lastname]}
  # #...
  # end
  # 
  #
  # :sphinx_search_by
  #
  # pass array of sphinx fields or :all symbol for use sphinx search instend of SQL query.
  #
  # When passed symbol :all used sphix method search without any conditions by all sphinx fields which indexes in model.
  #
  # auto_complete_for :tag, :name, :sphinx_search_by => :all (Used all indexes fields - tag.name, tag.descriptions, etc)
  #
  # When passed array of fields used conditions for search only by this fields
  #
  # Search only by sphinx field :name
  # auto_complete_for :tag, :name, :sphinx_search_by => [:name]
  #
  # Search only by sphinx fields :first_name and :last_name
  # auto_complete_for :tag, [:first_name, :last_name], :sphinx_search_by => [:first_name, :last_name]
  #
  # Search only by sphinx field :name
  # auto_complete_for :tag, [:first_name, :last_name], :sphinx_search_by => [:name]
  #
  # For last example you may have next sphinx configuration
  # define_index do
  #  indexes description
  #  indexes [:first_name, :last_name], :as => :name, :sortable => true
  # end

  
  module ClassMethods

    def auto_complete_for(object, method=[], options = {})
      if options.has_key?(:collection_instance_variable) && method.is_a?(Array)
        raise(ArgumentError, "method array cannot be combined with :collection_instance_variable option")
      end

      # define_method should not require array, allow non array input
      method = [method] unless method.is_a?(Array)
      method_name = options.delete(:method_name) || "auto_complete_for_#{object}_#{method.join("_")}"

      define_method(method_name) do
        object_constant = object.to_s.camelize.constantize
        ac_options = options.dup
        ac_options[:delimiter] ||= " "
        ac_options[:order] ||= "#{method.first} ASC"
        
        delimiter = ac_options[:delimiter]
        ac_options.delete :delimiter
        limit = ac_options[:limit] || 10
        associations = ac_options[:associations] if !ac_options[:associations].blank? && ac_options[:associations].is_a?(Hash)
        ac_options.delete :associations

        collection_instance_variable = ac_options.delete(:collection_instance_variable)

        sphinx_fields = ac_options.delete(:sphinx_search_by)

        if collection_instance_variable
          collection = instance_variable_get('@' + collection_instance_variable.to_s)
          if collection
            filter = params[:q].to_s.downcase
            filter_by = ac_options.delete(:collection_filter_by) || method.first.to_s
            items = collection.find_all { |item| 
              filter_for = item.send(filter_by).to_s.downcase
              filter_for.to_s =~ /#{filter}/
            }
            if items
              items.sort! { |a, b| a.send(filter_by) <=> b.send(filter_by) }
              # truncate at limit exclusive of the "limit" endpoint
              items = items[0...limit]
            end
          end
        else
          if sphinx_fields.blank?
            # assemble the conditions
            association_selects = ""
            association_conditions = ""
            conditions = ""
            selects = "#{object_constant.table_name}.id,"
            method = [method] unless method.is_a?(Array)
            fields_count = method.length
            method.each do |arg|
              conditions << "LOWER(#{object_constant.table_name}.#{arg}) LIKE ?"
              conditions << " OR " unless arg == method.last

              selects << "#{object_constant.table_name}.#{arg}"
              selects << "," unless arg == method.last
            end
            unless associations.blank?
              associations.each do |association,methods|
                association_table_name = object_constant.reflections[association.to_sym].table_name
                fields = [methods] unless methods.is_a?(Array)
                fields_count += fields.length
                fields.each do |arg|
                  association_conditions << "LOWER(#{association_table_name}.#{arg}) LIKE ?"
                  association_conditions << " OR " unless arg == fields.last

                  association_selects << "#{association_table_name}.#{arg}"
                  association_selects << "," unless arg == fields.last
                end
              end
            end

            conditions += " OR " + association_conditions unless association_conditions.blank?
            selects += ", " + association_selects unless association_selects.blank?
            
            conditions = Array(conditions)
            filters = Array("%#{params[:q].to_s.downcase}%")*fields_count
            filters.each { |filter| conditions.push filter }

            # These options can be overridden by the subsequent merge ac_options below
            find_options = {
              :conditions => conditions,
              :select => selects,
              :limit => limit }.merge!(ac_options)

            find_options.merge!({:include => associations.keys}) unless associations.blank?
            
            items = object_constant.find(:all, find_options)
          else
            if sphinx_fields.is_a?(Array)
              items = []
              sphinx_fields.each do |field|
                items += object_constant.search(:conditions => {field.to_s => "#{params[:q]}"}, :star => true, :per_page => limit)
              end
              if sphinx_fields.size > 1 && !items.blank?
                uniq_items = [items[0]]
                ids = [items[0].id]
                items[1..-1].each do |item|
                  unless ids.include?(item.id)
                    uniq_items << item
                    ids << item.id
                  end
                end
                items = uniq_items
                items.sort! { |a, b| a.send(method.first) <=> b.send(method.first) }
                # truncate at limit exclusive of the "limit" endpoint
                items = items[0...limit]
              end
            else
              items = object_constant.search(params[:q], :star => true, :per_page => limit) if sphinx_fields.to_s == "all"
            end
          end
        end

        content = ""
        if block_given?
          content = yield(items)
        elsif items
          content = items.map{ |item| 
            values = []
            method.each do |m|
              values << item.send(m)
            end
            unless associations.blank?
              associations.each do |a,m|
                values << item.send(a.to_sym).send(m.to_s)
              end
            end
            "#{values.join(delimiter)}|#{item.send(object_constant.primary_key)}"
          }.join("\n")
        end

        render :text => content 

      end
    end
  end
  
end
ActionController::Base.send :include, AutoCompleteJquery

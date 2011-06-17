module ActsAsTaggableOn::Taggable
  module Core
    def self.included(base)
      base.send :include, ActsAsTaggableOn::Taggable::Core::InstanceMethods
      base.extend ActsAsTaggableOn::Taggable::Core::ClassMethods

      base.class_eval do
        attr_writer :custom_contexts
        after_save :save_tags
      end

      base.initialize_acts_as_taggable_on_core
    end

    module ClassMethods
      def initialize_acts_as_taggable_on_core
        tag_types.each do |tags_type|
          tag_type         = tags_type.to_s.singularize
          context_taggings = "#{tag_type}_taggings".to_sym
          context_tags     = tags_type.to_sym

          class_eval do
            has_many context_taggings, :as => :taggable, :dependent => :destroy, :include => :tag, :class_name => acts_as_taggable_on_tagging_model.name,
            :conditions => ["#{acts_as_taggable_on_tagging_model.table_name}.tag_id = #{acts_as_taggable_on_tag_model.table_name}.id AND #{acts_as_taggable_on_tagging_model.table_name}.context = ?", tags_type]
            has_many context_tags, :through => context_taggings, :source => :tag, :class_name => acts_as_taggable_on_tag_model.name
          end

          class_eval %(
            def #{tag_type}_list
              tag_list_on('#{tags_type}')
            end

            def #{tag_type}_list=(new_tags)
              set_tag_list_on('#{tags_type}', new_tags)
            end

            def all_#{tags_type}_list
              all_tags_list_on('#{tags_type}')
            end
          )
        end
      end

      def acts_as_taggable_on(*args)
        super
        initialize_acts_as_taggable_on_core
      end

      # all column names are necessary for PostgreSQL group clause
      def grouped_column_names_for(object)
        if object.connection.adapter_name == 'PostgreSQL'
          object.column_names.map { |column| "#{object.table_name}.#{column}" }.join(", ")
        else
          "#{object.table_name}.#{object.primary_key}"
        end
      end

      ##
      # Return a scope of objects that are tagged with the specified tags.
      #
      # @param tags The tags that we want to query for
      # @param [Hash] options A hash of options to alter you query:
      #                       * <tt>:exclude</tt> - if set to true, return objects that are *NOT* tagged with the specified tags
      #                       * <tt>:any</tt> - if set to true, return objects that are tagged with *ANY* of the specified tags
      #                       * <tt>:match_all</tt> - if set to true, return objects that are *ONLY* tagged with the specified tags
      #
      # Example:
      #   User.tagged_with("awesome", "cool")                     # Users that are tagged with awesome and cool
      #   User.tagged_with("awesome", "cool", :exclude => true)   # Users that are not tagged with awesome or cool
      #   User.tagged_with("awesome", "cool", :any => true)       # Users that are tagged with awesome or cool
      #   User.tagged_with("awesome", "cool", :match_all => true) # Users that are tagged with just awesome and cool
      def tagged_with(tags, options = {})
        tag_list = ActsAsTaggableOn::Taggable::TagList.from(tags)

        joins = []
        conditions = []

        context = options.delete(:on)
        context_condition = context.blank? ? "" : sanitize_sql([" AND #{acts_as_taggable_on_tagging_model.table_name}.context = ?", context.to_s])

        if options.delete(:exclude)
          tags_conditions = tag_list.map { |t| sanitize_sql(["#{acts_as_taggable_on_tag_model.table_name}.name #{ActsAsTaggableOn.like_operator} ?", t]) }.join(" OR ")
          conditions << "#{table_name}.#{primary_key} NOT IN (SELECT #{acts_as_taggable_on_tagging_model.table_name}.taggable_id FROM #{acts_as_taggable_on_tagging_model.table_name} JOIN #{acts_as_taggable_on_tag_model.table_name} ON #{acts_as_taggable_on_tagging_model.table_name}.tag_id = #{acts_as_taggable_on_tag_model.table_name}.id AND (#{tags_conditions}) WHERE #{acts_as_taggable_on_tagging_model.table_name}.taggable_type = #{quote_value(base_class.name)} #{context_condition})"

        elsif options.delete(:any)
          tags_conditions = tag_list.map { |t| sanitize_sql(["#{acts_as_taggable_on_tag_model.table_name}.name #{ActsAsTaggableOn.like_operator} ?", t]) }.join(" OR ")
          conditions << "#{table_name}.#{primary_key} IN (SELECT #{acts_as_taggable_on_tagging_model.table_name}.taggable_id FROM #{acts_as_taggable_on_tagging_model.table_name} JOIN #{acts_as_taggable_on_tag_model.table_name} ON #{acts_as_taggable_on_tagging_model.table_name}.tag_id = #{acts_as_taggable_on_tag_model.table_name}.id AND (#{tags_conditions}) WHERE #{acts_as_taggable_on_tagging_model.table_name}.taggable_type = #{quote_value(base_class.name)} #{context_condition})"

        elsif tag_list.empty? && options[:match_all]
          conditions << "#{table_name}.#{primary_key} NOT IN (SELECT #{acts_as_taggable_on_tagging_model.table_name}.taggable_id FROM #{acts_as_taggable_on_tagging_model.table_name} WHERE #{acts_as_taggable_on_tagging_model.table_name}.taggable_type = #{quote_value(base_class.name)} #{context_condition})"

        else
          tags = acts_as_taggable_on_tag_model.named_any(tag_list)
          return where("1 = 0") unless tags.length == tag_list.length

          tags.each do |tag|
            safe_tag = tag.name.gsub(/[^a-zA-Z0-9]/, '')
            prefix   = "#{safe_tag}_#{rand(1024)}"

            taggings_alias = "#{undecorated_table_name}_taggings_#{prefix}"

            tagging_join  = "JOIN #{acts_as_taggable_on_tagging_model.table_name} #{taggings_alias}" +
                            "  ON #{taggings_alias}.taggable_id = #{table_name}.#{primary_key}" +
                            " AND #{taggings_alias}.taggable_type = #{quote_value(base_class.name)}" +
                            " AND #{taggings_alias}.tag_id = #{tag.id}"
            tagging_join << context_condition if context

            joins << tagging_join
          end
        end

        taggings_alias, tags_alias = "#{undecorated_table_name}_taggings_group", "#{undecorated_table_name}_tags_group"

        if options.delete(:match_all) && !tag_list.empty?
          joins << "LEFT OUTER JOIN #{acts_as_taggable_on_tagging_model.table_name} #{taggings_alias}" +
                   "  ON #{taggings_alias}.taggable_id = #{table_name}.#{primary_key}" +
                   " AND #{taggings_alias}.taggable_type = #{quote_value(base_class.name)}"

          group = "#{grouped_column_names_for(self)} HAVING COUNT(#{taggings_alias}.taggable_id) = #{tags.size}"
        end


        where(conditions.join(" AND ")).
          joins(joins.join(" ")).
          group(group).
          order(options[:order]).
          readonly(false)
      end

      def is_taggable?
        true
      end
    end

    module InstanceMethods
      # all column names are necessary for PostgreSQL group clause
      def grouped_column_names_for(object)
        self.class.grouped_column_names_for(object)
      end

      def custom_contexts
        @custom_contexts ||= []
      end

      def is_taggable?
        self.class.is_taggable?
      end

      def add_custom_context(value)
        value = value.to_s
        custom_contexts << value unless tagging_contexts.include?(value)
      end

      def cached_tag_list_on(context)
        self["cached_#{context.to_s.singularize}_list"]
      end

      def tag_list_cache_set_on(context)
        variable_name = "@#{context.to_s.singularize}_list"
        !instance_variable_get(variable_name).nil?
      end

      def tag_list_cache_on(context)
        variable_name = "@#{context.to_s.singularize}_list"
        instance_variable_get(variable_name) || instance_variable_set(variable_name, ActsAsTaggableOn::Taggable::TagList.new(tags_on(context).names))
      end

      def tag_list_on(context)
        add_custom_context(context)
        tag_list_cache_on(context)
      end

      def all_tags_list_on(context)
        variable_name = "@all_#{context.to_s.singularize}_list"
        return instance_variable_get(variable_name) if instance_variable_get(variable_name)

        instance_variable_set(variable_name, ActsAsTaggableOn::Taggable::TagList.new(all_tags_on(context).names).freeze)
      end

      ##
      # Returns all tags of a given context
      def all_tags_on(context)
        base_tags.where(:taggings => {:context => context.to_s}).
          group(grouped_column_names_for(acts_as_taggable_on_tag_model)).
          order("max(#{acts_as_taggable_on_tagging_model.table_name}.created_at)")
      end

      ##
      # Returns all tags that are not owned of a given context
      def tags_on(context)
        base_tags.where(["#{acts_as_taggable_on_tagging_model.table_name}.context = ? AND #{acts_as_taggable_on_tagging_model.table_name}.tagger_id IS NULL", context.to_s])
      end

      def set_tag_list_on(context, new_list)
        add_custom_context(context)

        variable_name = "@#{context.to_s.singularize}_list"
        instance_variable_set(variable_name, ActsAsTaggableOn::Taggable::TagList.from(new_list))
      end

      def tagging_contexts
        custom_contexts + self.class.tag_types.map {|type| type.to_s }
      end

      def reload(*args)
        self.class.tag_types.each do |context|
          instance_variable_set("@#{context.to_s.singularize}_list", nil)
          instance_variable_set("@all_#{context.to_s.singularize}_list", nil)
        end

        super
      end

      def save_tags
        tagging_contexts.each do |context|
          next unless tag_list_cache_set_on(context)

          tag_list = tag_list_cache_on(context).uniq

          # Find existing tags or create non-existing tags:
          tag_list = acts_as_taggable_on_tag_model.find_or_create_all_with_like_by_name(tag_list)

          current_tags = tags_on(context)
          old_tags     = current_tags - tag_list
          new_tags     = tag_list     - current_tags

          # Find taggings to remove:
          old_taggings = taggings.where(:tagger_type => nil, :tagger_id => nil,
                                        :context => context.to_s, :tag_id => old_tags)

          if old_taggings.present?
            # Destroy old taggings:
            acts_as_taggable_on_tagging_model.destroy_all :id => old_taggings.map {|tagging| tagging.id }
          end

          # Create new taggings:
          new_tags.each do |tag|
            taggings.create!(:tag_id => tag.id, :context => context.to_s, :taggable => self)
          end
        end

        true
      end
    end
  end
end

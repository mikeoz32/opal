module LF
  module Data
    class MigrationSet
      include Enumerable(Migration)

      @migrations : Array(Migration)

      def initialize
        @migrations = [] of Migration
      end

      def initialize(*migrations : Migration)
        @migrations = [] of Migration
        migrations.each { |migration| @migrations << migration }
        validate!
      end

      def each(& : Migration ->) : Nil
        @migrations.each { |migration| yield migration }
      end

      def validate! : Nil
        seen = {} of Int64 => String
        previous_version = nil.as(Int64?)
        previous_name = nil.as(String?)

        @migrations.each do |migration|
          version = migration.version
          name = migration.name

          if version <= 0
            raise MigrationError.new(:invalid_version, version, name)
          end
          if name.empty?
            raise MigrationError.new(:empty_name, version, name)
          end
          if existing_name = seen[version]?
            raise DuplicateMigrationVersionError.new(version, existing_name, name)
          end
          if previous = previous_version
            if version <= previous
              raise MigrationOrderError.new(
                previous,
                previous_name.not_nil!,
                version,
                name
              )
            end
          end

          seen[version] = name
          previous_version = version
          previous_name = name
        end
      end
    end
  end
end

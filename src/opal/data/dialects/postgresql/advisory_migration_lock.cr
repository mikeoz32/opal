module LF
  module Data
    module Dialects
      class PostgreSQL
        class AdvisoryMigrationLock < LF::Data::MigrationLock
          ACQUIRE_SQL = "SELECT pg_try_advisory_lock(" \
                        "hashtext(current_database()), hashtext($1))"
          RELEASE_SQL = "SELECT pg_advisory_unlock(" \
                        "hashtext(current_database()), hashtext($1))"

          getter? acquired = false

          def initialize(
            @connection : DB::Connection,
            @dialect_name : String,
            @namespace : String,
            @timeout : Time::Span,
            @poll_interval : Time::Span,
          )
          end

          def acquire : Nil
            return if acquired?

            deadline = Time.instant + @timeout
            loop do
              locked = @connection.query_one(
                ACQUIRE_SQL,
                @namespace,
                as: Bool
              )
              if locked
                @acquired = true
                return
              end

              if Time.instant >= deadline
                raise MigrationLockTimeoutError.new(
                  @dialect_name,
                  @namespace,
                  @timeout
                )
              end
              sleep @poll_interval
            end
          end

          def release : Nil
            return unless acquired?

            released = @connection.query_one(
              RELEASE_SQL,
              @namespace,
              as: Bool
            )
            unless released
              raise MigrationLockReleaseError.new(
                @dialect_name,
                @namespace
              )
            end
            @acquired = false
          end
        end
      end
    end
  end
end

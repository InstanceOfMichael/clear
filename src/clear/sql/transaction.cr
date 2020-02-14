module Clear::SQL::Transaction

  # Represents the differents levels of transactions
  #   as described in https://www.postgresql.org/docs/9.5/transaction-iso.html
  #
  #   ReadUncommited is voluntarly ommited as it fallback to ReadCommited in PostgreSQL
  enum Level
    ReadCommitted
    RepeatableRead
    Serializable

    # :nodoc:
    def to_begin_operation

      case self
      when ReadCommitted
        "BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED"
      when RepeatableRead
        "BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ"
      else # Serializable is the default
        "BEGIN"
      end

    end
  end

  @@savepoint_uid : UInt64 = 0_u64
  @@commit_callbacks = Hash( DB::Database, Array(DB::Database -> Void) ).new { [] of DB::Database -> Void }

  # Check whether the current pair of fiber/connection is in transaction
  # block or not.
  def in_transaction?(connection = "default")
    Clear::SQL::ConnectionPool.with_connection(connection, &._clear_in_transaction?)
  end

  # Enter new transaction block for the current connection/fiber pair.
  #
  # Example:
  # ```
  # Clear::SQL.transaction do
  #   # do something
  #   Clear::SQL.transaction do # Technically, this block do nothing, since we already are in transaction
  #     rollback                # < Rollback the up-most `transaction` block.
  #   end
  # end
  # ```
  # see #with_savepoint to use a stackable version using savepoints.
  #
  def transaction(connection = "default", level : Level = Level::Serializable, &block)
    Clear::SQL::ConnectionPool.with_connection(connection) do |cnx|
      has_rollback = false

      if cnx._clear_in_transaction?
        return yield(cnx) # In case we already are in transaction, we just ignore
      else
        cnx._clear_in_transaction = true
        execute(level.to_begin_operation)
        begin
          return yield(cnx)
        rescue e
          has_rollback = true
          is_rollback_error = e.is_a?(RollbackError) || e.is_a?(CancelTransactionError)
          execute("ROLLBACK --" + (is_rollback_error ? "normal" : "program error")) rescue nil
          raise e unless is_rollback_error
        ensure
          cnx._clear_in_transaction = false
          unless has_rollback
            execute("COMMIT")
            @@commit_callbacks[cnx].each(&.call(cnx))
            @@commit_callbacks.delete(cnx)
          end
        end
      end
    end
  end


  # Register a callback function which will be fired once when SQL `COMMIT`
  # operation is called
  #
  # This can be used for example to send email, or perform others tasks
  # when you want to be sure the data is secured in the database.
  #
  # ```
  #   transaction do
  #     @user = User.find(1)
  #     @user.subscribe!
  #     Clear::SQL.after_commit{ Email.deliver(ConfirmationMail.new(@user)) }
  #   end
  # ```
  #
  # In case the transaction fail and eventually rollback, the code won't be called.
  #
  def after_commit(connection = "default", &block : DB::Database -> Void )
    Clear::SQL::ConnectionPool.with_connection(connection) do |cnx|
      if cnx._clear_in_transaction?
        @@commit_callbacks[cnx] <<= block
      else
        raise Clear::SQL::Error.new("you need to be in transaction to add after_commit callback")
      end
    end
  end

  # Create a transaction, but this one is stackable
  # using savepoints.
  #
  # Example:
  # ```
  # Clear::SQL.with_savepoint do
  #   # do something
  #   Clear::SQL.with_savepoint do
  #     rollback # < Rollback only the last `with_savepoint` block
  #   end
  # end
  # ```
  def with_savepoint(connection_name = "default", &block)
    transaction do |cnx|
      sp_name = "sp_#{@@savepoint_uid += 1}"
      begin
        execute(connection_name, "SAVEPOINT #{sp_name}")
        yield
        execute(connection_name, "RELEASE SAVEPOINT #{sp_name}") if cnx._clear_in_transaction?
      rescue e : RollbackError
        execute(connection_name, "ROLLBACK TO SAVEPOINT #{sp_name}") if cnx._clear_in_transaction?
      end
    end
  end

  # Raise a rollback, in case of transaction
  def rollback
    raise RollbackError.new
  end

end
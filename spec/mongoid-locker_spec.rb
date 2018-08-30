require File.join(File.dirname(__FILE__), 'spec_helper')

describe Mongoid::Locker do
  def remove_class(klass)
    Object.send :remove_const, klass.to_s.to_sym
  end

  shared_examples 'Mongoid::Locker is included' do
    describe '#locked?' do
      it "shouldn't be locked when created" do
        expect(@user.locked?).to be false
      end

      it 'should be true when locked' do
        @user.with_lock do
          expect(@user.locked?).to be true
        end
      end

      it 'should respect the expiration' do
        User.timeout_lock_after 1

        @user.with_lock do
          sleep 2
          expect(@user.locked?).to be false
        end
      end

      it 'should be true for a different instance' do
        @user.with_lock do
          expect(User.first.locked?).to be true
        end
      end
    end

    describe '#has_lock?' do
      it "shouldn't be has_lock when created" do
        expect(@user.has_lock?).to be false
      end

      it 'should be true when has_lock' do
        @user.with_lock do
          expect(@user.has_lock?).to be true
        end
      end

      it 'should respect the expiration' do
        User.timeout_lock_after 1

        @user.with_lock do
          sleep 2
          expect(@user.has_lock?).to be false
        end
      end

      it 'should be false for a different instance' do
        @user.with_lock do
          expect(User.first.has_lock?).to be false
        end
      end
    end

    describe '#with_lock' do
      it 'should lock and unlock the user' do
        @user.with_lock do
          expect(@user).to be_locked
          expect(User.first).to be_locked
        end

        expect(@user).to_not be_locked
        expect(@user.reload).to_not be_locked
      end

      it "shouldn't save the full document" do
        @user.with_lock do
          @user.account_balance = 10
        end

        expect(@user.account_balance).to eq(10)
        expect(User.first.account_balance).to eq(20)
      end

      it 'should handle errors gracefully' do
        expect do
          @user.with_lock do
            raise 'booyah!'
          end
        end.to raise_error 'booyah!'

        expect(@user.reload).to_not be_locked
      end

      it 'should complain if trying to lock locked doc' do
        @user.with_lock do
          user_dup = User.first

          expect do
            user_dup.with_lock do
              raise "shouldn't get the lock"
            end
          end.to raise_error(Mongoid::Locker::LockError)
        end
      end

      it 'should handle recursive calls' do
        @user.with_lock do
          @user.with_lock do
            @user.account_balance = 10
          end
        end

        expect(@user.account_balance).to eq(10)
      end

      it 'should wait until the lock times out, if desired' do
        User.timeout_lock_after 1

        @user.with_lock do
          user_dup = User.first

          user_dup.with_lock wait: true do
            user_dup.account_balance = 10
            user_dup.save!
          end
        end

        expect(@user.reload.account_balance).to eq(10)
      end

      it 'should, by default, reload the row after acquiring the lock' do
        expect(@user).to receive(:reload)
        @user.with_lock do
          # no-op
        end
      end

      it 'should allow override of the default reload behavior' do
        expect(@user).to_not receive(:reload)
        @user.with_lock reload: false do
          # no-op
        end
      end

      it 'should, by default, not retry' do
        expect(@user).to receive(:acquire_lock).once.and_return(true)
        @user.with_lock do
          user_dup = User.first

          user_dup.with_lock do
            # no-op
          end
        end
      end

      it 'should retry the number of times given, if desired' do
        allow(@user).to receive(:acquire_lock).and_return(false)
        allow(Mongoid::Locker::Wrapper).to receive(:locked_until).and_return(Time.now.utc)

        expect(@user).to receive(:acquire_lock).exactly(6).times
        expect do
          @user.with_lock retries: 5 do
            # no-op
          end
        end.to raise_error(Mongoid::Locker::LockError)
      end

      it 'does not fail if the lock has been released between check and sleep time calculation' do
        allow(@user).to receive(:acquire_lock).and_return(false)
        allow(Mongoid::Locker::Wrapper).to receive(:locked_until).and_return(nil)

        expect(@user).to receive(:acquire_lock).exactly(2).times
        expect do
          @user.with_lock retries: 1 do
            # no-op
          end
        end.to raise_error(Mongoid::Locker::LockError)
      end

      it 'should, by default, when retrying, sleep until the lock expires' do
        allow(@user).to receive(:acquire_lock).and_return(false)
        allow(Mongoid::Locker::Wrapper).to receive(:locked_until).and_return(Time.now.utc + 5.seconds)
        allow(@user).to receive(:sleep) { |time| expect(time).to be_within(0.1).of(5) }

        expect do
          @user.with_lock retries: 1 do
            # no-op
          end
        end.to raise_error(Mongoid::Locker::LockError)
      end

      it 'should sleep for the time given, if desired' do
        allow(@user).to receive(:acquire_lock).and_return(false)
        allow(@user).to receive(:sleep) { |time| expect(time).to be_within(0.1).of(3) }

        expect do
          @user.with_lock(retries: 1, retry_sleep: 3) do
            # no-op
          end
        end.to raise_error(Mongoid::Locker::LockError)
      end

      it 'should override the default timeout' do
        User.timeout_lock_after 1

        expiration = (Time.now.utc + 3).to_i
        @user.with_lock timeout: 3 do
          expect(@user[@user.locked_until_field].to_i).to eq(expiration)
        end
      end

      it 'should reload the document if it needs to wait for a lock' do
        User.timeout_lock_after 1

        @user.with_lock do
          user_dup = User.first

          @user.account_balance = 10
          @user.save!

          expect(user_dup.account_balance).to eq(20)
          user_dup.with_lock wait: true do
            expect(user_dup.account_balance).to eq(10)
          end
        end
      end

      it 'should succeed for subclasses' do
        class Admin < User
        end

        admin = Admin.create!

        admin.with_lock do
          expect(admin).to be_locked
          expect(Admin.first).to be_locked
        end

        expect(admin).to_not be_locked
        expect(admin.reload).to_not be_locked

        remove_class Admin
      end

      context 'when a lock has timed out' do
        before do
          User.timeout_lock_after 1
          @user.with_lock do
            expect(@user).to be_locked
            expect(User.first).to be_locked
            sleep 2
          end
        end
        it 'should remain unlocked' do
          expect(@user).to_not receive(:unlock)
          expect(@user).to_not be_locked
          expect(@user.reload).to_not be_locked
        end
      end

      context 'when fields are not defined' do
        before do
          class Admin
            include Mongoid::Document
            include Mongoid::Locker
          end
        end

        after do
          Admin.delete_all
          remove_class Admin
        end

        it 'should return error if locked_at field is not defined' do
          Admin.field(:locked_until, type: Time)
          admin = Admin.create!

          expect do
            admin.with_lock do
              # no-op
            end
          end.to raise_error(Mongoid::Errors::UnknownAttribute)
        end

        it 'should return error if locked_until field is not defined' do
          Admin.field(:locked_at, type: Time)
          admin = Admin.create!

          expect do
            admin.with_lock do
              # no-op
            end
          end.to raise_error(Mongoid::Errors::UnknownAttribute)
        end
      end
    end

    describe '#locked_at_field' do
      it 'should be defined' do
        expect(User.public_method_defined?(:locked_at_field)).to be_truthy
      end

      it 'should return @@locked_at_field variable value' do
        expect(@user.locked_at_field).to eq(User.class_variable_get(:@@locked_at_field))
      end
    end

    describe '#locked_until_field' do
      it 'should be defined' do
        expect(User.public_method_defined?(:locked_until_field)).to be_truthy
      end

      it 'should return @@locked_until_field variable value' do
        expect(@user.locked_until_field).to eq(User.class_variable_get(:@@locked_until_field))
      end
    end

    describe '.timeout_lock_after' do
      it 'should ignore the lock if it has timed out' do
        User.timeout_lock_after 1

        @user.with_lock do
          user_dup = User.first
          sleep 2

          user_dup.with_lock do
            user_dup.account_balance = 10
            user_dup.save!
          end
        end

        expect(@user.reload.account_balance).to eq(10)
      end

      it 'should be independent for different classes' do
        class Account
          include Mongoid::Document
          include Mongoid::Locker
        end

        User.timeout_lock_after 1
        Account.timeout_lock_after 2

        expect(User.lock_timeout).to eq(1)

        remove_class Account
      end
    end

    describe '.locked' do
      it 'should return the locked documents' do
        User.create!

        @user.with_lock do
          expect(User.locked.to_a).to eq([@user])
        end
      end

      it 'shouldnt throw error while unlocking destroyed object' do
        User.create!

        @user.with_lock do
          @user.destroy
        end
      end
    end

    describe '.unlocked' do
      it 'should return the unlocked documents' do
        user2 = User.create!

        @user.with_lock do
          expect(User.unlocked.to_a).to eq([user2])
        end
      end
    end

    describe '.locked_at_field' do
      it 'should be defined' do
        expect(User.singleton_methods).to include(:locked_at_field)
      end

      it 'should return @@locked_at_field variable value' do
        expect(User.locked_at_field).to eq(User.class_variable_get(:@@locked_at_field))
      end
    end

    describe '.locked_until_field' do
      it 'should be defined' do
        expect(User.singleton_methods).to include(:locked_until_field)
      end

      it 'should return @@locked_until_field variable value' do
        expect(User.locked_until_field).to eq(User.class_variable_get(:@@locked_until_field))
      end
    end

    describe '.locker' do
      it 'should set locked_at_field name' do
        User.locker(locked_at_field: :locker_locked_at)

        expect(User.locked_at_field).to eq(:locker_locked_at)
        expect(User.locked_at_field).to_not eq(Mongoid::Locker.locked_at_field)
      end

      it 'should set locked_until_field name' do
        User.locker(locked_until_field: :locker_locked_until)

        expect(User.locked_until_field).to eq(:locker_locked_until)
        expect(User.locked_until_field).to_not eq(Mongoid::Locker.locked_until_field)
      end
    end

    describe '::locked_at_field' do
      it 'should be defined' do
        expect(Mongoid::Locker.singleton_methods).to include(:locked_at_field)
      end

      it '@locked_at_field variable should be defined' do
        expect(Mongoid::Locker.instance_variable_defined?(:@locked_at_field)).to be_truthy
      end
    end

    describe '::locked_at_field=' do
      before do
        @field_name = Mongoid::Locker.locked_at_field
      end

      after do
        Mongoid::Locker.locked_at_field = @field_name
      end

      it 'should be defined' do
        expect(Mongoid::Locker.singleton_methods).to include(:locked_at_field=)
      end

      it 'should assign the value' do
        Mongoid::Locker.locked_at_field = :dks17_locked_at

        expect(Mongoid::Locker.locked_at_field).to eq(:dks17_locked_at)
        expect(Mongoid::Locker.locked_at_field).to eq(Mongoid::Locker.instance_variable_get(:@locked_at_field))
      end
    end

    describe '::locked_until_field' do
      it 'should be defined' do
        expect(Mongoid::Locker.singleton_methods).to include(:locked_until_field)
      end

      it '@locked_until_field variable should be defined' do
        expect(Mongoid::Locker.instance_variable_defined?(:@locked_until_field)).to be_truthy
      end
    end

    describe '::locked_until_field=' do
      before do
        @field_name = Mongoid::Locker.locked_until_field
      end

      after do
        Mongoid::Locker.locked_until_field = @field_name
      end

      it 'should be defined' do
        expect(Mongoid::Locker.singleton_methods).to include(:locked_until_field=)
      end

      it 'should assign the value' do
        Mongoid::Locker.locked_until_field = :dks17_locked_until

        expect(Mongoid::Locker.locked_until_field).to eq(:dks17_locked_until)
        expect(Mongoid::Locker.locked_until_field).to eq(Mongoid::Locker.instance_variable_get(:@locked_until_field))
      end
    end

    describe '::configure' do
      it 'should be defined' do
        expect(Mongoid::Locker.singleton_methods).to include(:configure)
      end

      it 'should pass module name into block' do
        Mongoid::Locker.configure do |config|
          expect(config).to eq(Mongoid::Locker)
        end
      end
    end

    describe '::reset!' do
      it 'should reset to default configuration' do
        locked_at    = :reset_locked_at
        locked_until = :reset_locked_until

        Mongoid::Locker.configure do |config|
          config.locked_at_field = locked_at
          config.locked_until_field = locked_until
        end

        expect(Mongoid::Locker.locked_at_field).to eq(locked_at)
        expect(Mongoid::Locker.locked_until_field).to eq(locked_until)

        Mongoid::Locker.reset!

        expect(Mongoid::Locker.locked_at_field).to eq(:locked_at)
        expect(Mongoid::Locker.locked_until_field).to eq(:locked_until)
      end
    end
  end

  context 'with default configuration' do
    before do
      # recreate the class for each spec
      class User
        include Mongoid::Document
        include Mongoid::Locker

        field :locked_at, type: Time
        field :locked_until, type: Time
        field :account_balance, type: Integer # easier to test than Float
      end

      @user = User.create! account_balance: 20
    end

    after do
      User.delete_all
      remove_class User
    end

    it_behaves_like 'Mongoid::Locker is included'
  end

  context 'with global configuration' do
    before do
      Mongoid::Locker.configure do |config|
        config.locked_at_field = :global_locked_at
        config.locked_until_field = :global_locked_until
      end

      class User
        include Mongoid::Document
        include Mongoid::Locker

        field :global_locked_at, type: Time
        field :global_locked_until, type: Time
        field :account_balance, type: Integer # easier to test than Float
      end

      @user = User.create! account_balance: 20
    end

    after do
      User.delete_all
      remove_class User
    end

    it_behaves_like 'Mongoid::Locker is included'

    it '.locked_at_field should return global value' do
      expect(User.locked_at_field).to eq(Mongoid::Locker.locked_at_field)
    end

    it '.locked_until_field should return global value' do
      expect(User.locked_until_field).to eq(Mongoid::Locker.locked_until_field)
    end
  end

  context 'with locker configuration' do
    before do
      Mongoid::Locker.configure do |config|
        config.locked_at_field = :global_locked_at
        config.locked_until_field = :global_locked_until
      end

      class User
        include Mongoid::Document
        include Mongoid::Locker

        field :locker_locked_at, type: Time
        field :locker_locked_until, type: Time
        field :account_balance, type: Integer # easier to test than Float

        locker locked_at_field: :locker_locked_at,
               locked_until_field: :locker_locked_until
      end

      class Item
        include Mongoid::Document
        include Mongoid::Locker

        field :global_locked_at, type: Time
        field :global_locked_until, type: Time
      end

      @user = User.create! account_balance: 20
      @item = Item.create!
    end

    after do
      User.delete_all
      remove_class User

      Item.delete_all
      remove_class Item
    end

    it_behaves_like 'Mongoid::Locker is included'

    it '.locked_at_field should return locker value' do
      expect(User.locked_at_field).to eq(:locker_locked_at)
    end

    it '.locked_until_field should return locker value' do
      expect(User.locked_until_field).to eq(:locker_locked_until)
    end

    it '#locked_at_field should return locker value' do
      expect(@user.locked_at_field).to eq(:locker_locked_at)
    end

    it '#locked_until_field should return locker value' do
      expect(@user.locked_until_field).to eq(:locker_locked_until)
    end

    it '.locked_at_field should return global value for other class' do
      expect(Item.locked_at_field).to eq(Mongoid::Locker.locked_at_field)
    end

    it '.locked_until_field should return global value for other class' do
      expect(Item.locked_until_field).to eq(Mongoid::Locker.locked_until_field)
    end

    it '#locked_at_field should return global value for other class' do
      expect(@item.locked_at_field).to eq(Mongoid::Locker.locked_at_field)
    end

    it '#locked_until_field should return global value for other class' do
      expect(@item.locked_until_field).to eq(Mongoid::Locker.locked_until_field)
    end
  end
end

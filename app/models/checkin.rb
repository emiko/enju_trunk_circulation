class Checkin < ActiveRecord::Base
  attr_accessible :item_identifier, :librarian_id, :auto_checkin, :checked_at

  default_scope :order => 'id DESC'
  scope :on, lambda {|date| {:conditions => ['created_at >= ? AND created_at < ?', date.beginning_of_day, date.tomorrow.beginning_of_day]}}

  has_one :checkout
  belongs_to :item
  belongs_to :librarian, :class_name => 'User'
  belongs_to :basket

  validates_presence_of :item, :basket, :on => :update
  validates_associated :item, :librarian, :basket, :on => :update
  validates_presence_of :item_identifier, :on => :create

  attr_accessor :item_identifier
  attr_accessible :item_id

  after_create :store_history

  def item_checkin(current_user, escape_flag = false)
    message = []
    Checkin.transaction do
      checkouts = Checkout.not_returned.where(:item_id => self.item_id).select([:id, :item_id, :lock_version, :checkin_id])
      self.item.checkin! rescue nil # unless escape_flag

      #message << I18n.t('item.this_item_include_supplement') + '<br />' if self.item.include_supplements?
      message << 'item.this_item_include_supplement' if self.item.include_supplements?

      # for item on closing shelf
      message << 'item.close_shelf' unless self.item.shelf.open? 
   
      checkouts.each do |checkout|
        # TODO: ILL時の処理
        checkout.checkin_id = self.id
        checkout.save(:validate => false)
        # delete from reminder list
        ReminderList.delete_all(:checkout_id => checkout.id)

        #message << I18n.t('checkin.other_library_item') + '<br />' unless checkout.item.shelf.library == current_user.library
        if SystemConfiguration.get('use_inter_library_loan')
          unless escape_flag
            unless checkout.item.shelf.library.id == current_user.library.id
              message << 'checkin.other_library_item'
              InterLibraryLoan.new.request_for_checkin(self.item, current_user.library)
              return
            end
          end
        end
      end

      # set default librarian and checked_at
      self.librarian = current_user unless self.librarian_id
      self.checked_at = Time.now unless self.checked_at
      self.save! if self.changed?

      # checkout.user = nil unless checkout.user.save_checkout_history
      unless escape_flag
        if self.item.manifestation.next_reservation
          # TODO: もっと目立たせるために別画面を表示するべき？
          #message << I18n.t('item.this_item_is_reserved') + '<br />'
          if SystemConfiguration.get('reserve.auto_retain')
            self.item.retain(current_user)
            message << 'checkin.item_retained'
          else
            message << 'checkin.item_reserved'
          end
        end

        # 罰則管理
        if SystemConfiguration.get('penalty.user_penalty')
          penalty_update = 0
          user = self.checkout.user
          if user.in_penalty
            if user.checkouts.not_returned.count == 0
              user.in_penalty = false
              if user.user_group.restrict_checkout_after_penalty > 0
                user.days_after_penalty += 1 # TODO 観察回数
                penalty_update = 1
              end
            end
          end
          if user.days_after_penalty > 0 && penalty_update == 0 && user.checkouts.not_returned.count == 0
            if self.checkout.due_date >= Date.today
              user.days_after_penalty = user.days_after_penalty - 1
            end
          end
          user.save!
        end
      end

      # メールとメッセージの送信
      #ReservationNotifier.deliver_reserved(self.item.manifestation.reserves.first.user, self.item.manifestation)
      #Message.create(:sender => current_user, :receiver => self.item.manifestation.next_reservation.user, :subject => message_template.title, :body => message_template.body, :recipient => self.item.manifestation.next_reservation.user)
    end
    if message.present?
      message
    else
      nil
    end
  end

  def store_history
    CheckoutHistory.store_history("checkin", self) unless self.auto_checkin
  end
end

# == Schema Information
#
# Table name: checkins
#
#  id           :integer         not null, primary key
#  item_id      :integer         not null
#  librarian_id :integer
#  basket_id    :integer
#  created_at   :datetime
#  updated_at   :datetime
#


require 'logging'
require_dependency 'spree/order'

module Spree
  class AvalaraTransaction < ActiveRecord::Base
    AVALARA_TRANSACTION_LOGGER = AvataxHelper::AvataxLog.new("post_order_to_avalara", __FILE__)

    belongs_to :order
    belongs_to :return_authorization
    validates :order, presence: true
    has_one :adjustment, as: :source

    def rnt_tax
      @myrtntax
    end

    def amount
      @myrtntax
    end

    def lookup_avatax
      order_details = Spree::Order.find(self.order_id)
      post_order_to_avalara(false, order_details.line_items, order_details)
    end

    def commit_avatax(items, order_details,doc_id=nil,invoice_dt=nil)
      post_order_to_avalara(false, items, order_details,doc_id,invoice_dt)
    end

    def commit_avatax_final(items, order_details,doc_id=nil,invoice_dt=nil)
      if document_committing_enabled?
        post_order_to_avalara(true, items, order_details,doc_id,invoice_dt)
      end
    end

    def update_adjustment(adjustment, source)
      AVALARA_TRANSACTION_LOGGER.info("update adjustment call")

      if adjustment.state != "closed"
        commit_avatax(order.line_items, order)
        adjustment.update_column(:amount, rnt_tax)
      end

      if order.complete?
        commit_avatax_final(order.line_items, order)
        adjustment.update_column(:amount, rnt_tax)
        adjustment.update_column(:state, "closed")
      end

      if order.state == 'canceled'
        cancel_order_to_avalara("SalesInvoice", "DocVoided", order)
      end

      if adjustment.state == "closed" && order.adjustments.return_authorization.exists?
        commit_avatax(order.line_items, order, order.number.to_s + ":" + order.adjustments.return_authorization.first.id.to_s, order.completed_at)

        if rnt_tax != "0.00"
          adjustment.update_column(:amount, rnt_tax)
          adjustment.update_column(:state, "closed")
        end
      end

      if adjustment.state == "closed" && order.adjustments.return_authorization.exists?
        order.adjustments.return_authorization.each do |adj|
          if adj.state == "closed" || adj.state == "closed"
            commit_avatax_final(order.line_items, order, order.number.to_s + ":"  + adj.id.to_s, order.completed_at )
          end
        end

        if rnt_tax != "0.00"
          adjustment.update_column(:amount, rnt_tax)
          adjustment.update_column(:state, "closed")
        end
      end
    end


    private

    def get_shipped_from_address(item_id)
      AVALARA_TRANSACTION_LOGGER.info("shipping address get")

      stock_item = Stock_Item.find(item_id)
      shipping_address = stock_item.stock_location || nil
      return shipping_address
    end

    def cancel_order_to_avalara(doc_type="SalesInvoice", cancel_code="DocVoided", order_details=nil)
      AVALARA_TRANSACTION_LOGGER.info("cancel order to avalara")

      cancelTaxRequest = {
        :CompanyCode => Spree::Config.avatax_company_code,
        :DocType => doc_type,
        :DocCode => order_details.number,
        :CancelCode => cancel_code
      }

      AVALARA_TRANSACTION_LOGGER.debug cancelTaxRequest

      mytax = TaxSvc.new
      cancelTaxResult = mytax.cancel_tax(cancelTaxRequest)

      AVALARA_TRANSACTION_LOGGER.debug cancelTaxResult

      if cancelTaxResult == 'error in Tax' then
        return 'Error in Tax'
      else
        if cancelTaxResult["ResultCode"] = "Success"
          AVALARA_TRANSACTION_LOGGER.debug cancelTaxResult
          return cancelTaxResult
        end
      end
    end

    def post_order_to_avalara(commit=false, orderitems=nil, order_details=nil, doc_code=nil, org_ord_date=nil)
      AVALARA_TRANSACTION_LOGGER.info("post order to avalara")
      address_validator = AddressSvc.new
      tax_line_items = Array.new
      addresses = Array.new

      origin = JSON.parse(Spree::Config.avatax_origin)
      orig_address = Hash.new
      orig_address[:AddressCode] = "Orig"
      orig_address[:Line1] = origin["Address1"]
      orig_address[:City] = origin["City"]
      orig_address[:PostalCode] = origin["Zip5"]
      orig_address[:Country] = origin["Country"]
      AVALARA_TRANSACTION_LOGGER.debug orig_address.to_xml

      begin
        if order_details.user_id != nil
          myuserid = order_details.user_id
          AVALARA_TRANSACTION_LOGGER.debug myuserid
          myuser = Spree::User.find(myuserid)
          myusecode = Spree::AvalaraEntityUseCode.where(:id => myuser.avalara_entity_use_code_id).first
        end
      rescue => e
        AVALARA_TRANSACTION_LOGGER.debug e
        AVALARA_TRANSACTION_LOGGER.debug "error with order's user id"
      end

      i = 0

      if orderitems then

        orderitems.each do |line_item|
          line = Hash.new
          i += 1

          line[:LineNo] = i
          line[:ItemCode] = line_item.variant.sku
          line[:Qty] = line_item.quantity
          line[:Amount] = line_item.total.to_f
          line[:OriginCode] = "Orig"
          line[:DestinationCode] = "Dest"

          AVALARA_TRANSACTION_LOGGER.info('about to check for User')
          AVALARA_TRANSACTION_LOGGER.debug myusecode

          if myusecode
            line[:CustomerUsageType] = myusecode.use_code || ""
          end

          AVALARA_TRANSACTION_LOGGER.info('after user check')

          line[:Description] = line_item.name
          if line_item.tax_category.name
            line[:TaxCode] = line_item.tax_category.description || "P0000000"
          end

          AVALARA_TRANSACTION_LOGGER.info('about to check for shipped from')

          shipped_from = order_details.inventory_units.where(:variant_id => line_item.id)

          if Spree::StockLocation.find_by(name: 'default').nil?
            location = Spree::StockLocation.create(name: "avatax origin", address1: origin["Address1"], address2: origin["Address2"], city: origin["City"], state_id: Spree::State.find_by_name(origin["Region"]).id, state_name: origin["Region"] , zipcode: origin["Zip5"], country_id: Spree::State.find_by_name(origin["Region"]).country_id)
            AVALARA_TRANSACTION_LOGGER.info('avatax origin location created')
          elsif Spree::StockLocation.find_by(name: 'default').city.nil? || Spree::StockLocation.first.city.nil?
            location = Spree::StockLocation.first.update_attributes(address1: origin["Address1"], address2: origin["Address2"], city: origin["City"], state_id: Spree::State.find_by_name(origin["Region"]).id, state_name: origin["Region"] , zipcode: origin["Zip5"], country_id: Spree::State.find_by_name(origin["Region"]).country_id )
            AVALARA_TRANSACTION_LOGGER.info('avatax origin location updated default')
          else
            location = Spree::StockLocation.find_by(name: 'default') || Spree::StockLocation.first
            AVALARA_TRANSACTION_LOGGER.info('default location')
          end

          AVALARA_TRANSACTION_LOGGER.debug location

          packages = Spree::Stock::Coordinator.new(order_details).packages

          AVALARA_TRANSACTION_LOGGER.info('packages')
          AVALARA_TRANSACTION_LOGGER.debug packages

          stock_loc = nil

          packages.each do |package|
            next unless package.to_shipment.stock_location.stock_items.where(:variant_id => line_item.variant.id).exists?
            stock_loc = package.to_shipment.stock_location
            AVALARA_TRANSACTION_LOGGER.debug stock_loc
          end

          AVALARA_TRANSACTION_LOGGER.info('checked for shipped from')

          if stock_loc
            orig_ship_address = Hash.new
            orig_ship_address[:AddressCode] = line_item.id
            orig_ship_address[:Line1] = stock_loc.address1
            orig_ship_address[:City] = stock_loc.city
            orig_ship_address[:PostalCode] = stock_loc.zipcode
            orig_ship_address[:Country] = Country.find(stock_loc.country_id).iso

            line[:OriginCode] = line_item.id
            AVALARA_TRANSACTION_LOGGER.debug orig_ship_address.to_xml

            addresses<<orig_ship_address
          elsif location
            orig_ship_address = Hash.new
            orig_ship_address[:AddressCode] = line_item.id
            orig_ship_address[:Line1] = location.address1
            orig_ship_address[:City] = location.city
            orig_ship_address[:PostalCode] = location.zipcode
            orig_ship_address[:Country] = Country.find(location.country_id).iso

            line[:OriginCode] = line_item.id
            AVALARA_TRANSACTION_LOGGER.debug orig_ship_address.to_xml
            addresses<<orig_ship_address
          end

          AVALARA_TRANSACTION_LOGGER.debug line.to_xml

          tax_line_items<<line
        end
      end

      AVALARA_TRANSACTION_LOGGER.info('running order details')
      if order_details then
        AVALARA_TRANSACTION_LOGGER.info('order adjustments')

        order_details.adjustments.shipping.each do |adj|

          line = Hash.new
          i += 1

          line[:LineNo] = i
          line[:ItemCode] = "Shipping"
          line[:Qty] = "0"
          line[:Amount] = adj.amount.to_f
          line[:OriginCode] = "Orig"
          line[:DestinationCode] = "Dest"

          if myusecode
            line[:CustomerUsageType] = myusecode.use_code || ""
          end

          line[:Description] = adj.label
          line[:TaxCode] = Spree::ShippingMethod.where(:id => adj.originator_id).first.tax_code

          AVALARA_TRANSACTION_LOGGER.debug line.to_xml

          tax_line_items<<line
        end

        order_details.adjustments.promotion.each do |adj|

          line = Hash.new
          i += 1

          line[:LineNo] = i
          line[:ItemCode] = "Promotion"
          line[:Qty] = "0"
          line[:Amount] = adj.amount.to_f
          line[:OriginCode] = "Orig"
          line[:DestinationCode] = "Dest"

          if myusecode
            line[:CustomerUsageType] = myusecode.use_code || ""
          end

          line[:Description] = adj.label
          line[:TaxCode] = ""

          AVALARA_TRANSACTION_LOGGER.debug line.to_xml

          tax_line_items<<line
        end

        order_details.adjustments.return_authorization.each do |adj|

          line = Hash.new
          i += 1

          line[:LineNo] = i
          line[:ItemCode] = "Return Authorization"
          line[:Qty] = "0"
          line[:Amount] = adj.amount.to_f
          line[:OriginCode] = "Orig"
          line[:DestinationCode] = "Dest"

          if myusecode
            line[:CustomerUsageType] = myusecode.use_code || ""
          end

          line[:Description] = adj.label
          line[:TaxCode] = ""

          AVALARA_TRANSACTION_LOGGER.debug line.to_xml

          tax_line_items<<line
        end
      end

      if order_details.ship_address_id.nil?
        order_details.update_attributes(ship_address_id: order_details.bill_address_id)
      end

      response = address_validator.validate(order_details.ship_address)

      if response != nil
        if response["ResultCode"] == "Success"
          AVALARA_TRANSACTION_LOGGER.info("Address Validation Success")
        else
          AVALARA_TRANSACTION_LOGGER.info("Address Validation Failed")
        end
      end

      shipping_address = Hash.new

      shipping_address[:AddressCode] = "Dest"
      shipping_address[:Line1] = order_details.ship_address.address1
      shipping_address[:Line2] = order_details.ship_address.address2
      shipping_address[:City] = order_details.ship_address.city
      shipping_address[:Region] = order_details.ship_address.state_text
      shipping_address[:Country] = Country.find(order_details.ship_address.country_id).iso
      shipping_address[:PostalCode] = order_details.ship_address.zipcode

      AVALARA_TRANSACTION_LOGGER.debug shipping_address.to_xml

      addresses<<shipping_address
      addresses<<orig_address

      gettaxes = {
        :CustomerCode => myuser ? myuser.id : "Guest",
        :DocDate => org_ord_date ? org_ord_date : Date.current.to_formatted_s(:db),

        :CompanyCode => Spree::Config.avatax_company_code,
        :CustomerUsageType => myusecode ? myusecode.usecode : "",
        :ExemptionNo => myuser ? myuser.exemption_number : "",
        :Client =>  AVATAX_CLIENT_VERSION || "SpreeExtV2.3",
        :DocCode => doc_code ? doc_code : order_details.number,

        :ReferenceCode => order_details.number,
        :DetailLevel => "Tax",
        :Commit => commit,
        :DocType => "SalesInvoice",
        :Addresses => addresses,
        :Lines => tax_line_items
      }

      AVALARA_TRANSACTION_LOGGER.debug gettaxes

      mytax = TaxSvc.new

      getTaxResult = mytax.get_tax(gettaxes)

      AVALARA_TRANSACTION_LOGGER.debug getTaxResult

      if getTaxResult == 'error in Tax' then
        @myrtntax = "0.00"
      else
        if getTaxResult["ResultCode"] = "Success"
          AVALARA_TRANSACTION_LOGGER.info "total tax"
          AVALARA_TRANSACTION_LOGGER.debug getTaxResult["TotalTax"].to_s
          @myrtntax = getTaxResult["TotalTax"].to_s
        end
      end
      return @myrtntax
    end
    def document_committing_enabled?
      Spree::Config.avatax_document_commit
    end
  end
end

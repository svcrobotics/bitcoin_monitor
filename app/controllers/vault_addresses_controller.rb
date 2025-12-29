class VaultAddressesController < ApplicationController
  def index
    @vault = Vault.find(params[:vault_id])

    @addresses = VaultAddress
      .where(vault_id: @vault.id)
      .order(Arel.sql("CASE kind WHEN 'receive' THEN 0 WHEN 'change' THEN 1 ELSE 2 END"), :index)
  end
end

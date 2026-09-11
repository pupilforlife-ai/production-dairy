begin;

alter table public.source_lots
add column invoice_number text,
add column received_from text,
add constraint source_lots_invoice_number_not_blank_check check (
  invoice_number is null or length(trim(invoice_number)) > 0
),
add constraint source_lots_received_from_not_blank_check check (
  received_from is null or length(trim(received_from)) > 0
);

create index source_lots_invoice_number_idx
on public.source_lots (invoice_number)
where invoice_number is not null;

commit;

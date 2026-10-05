import sys
W='/Users/np1076/dev/spk/owl/.claude/worktrees/oms-laravel-api/SBDEV-2624/'
SVC=W+'app/Services/WmsApiService.php'
PC=W+'app/Http/Controllers/Api/ProductController.php'
LOOP="""        $results = [];
        foreach ($facilities as $facility) {
            $results[$facility] = $this->updateSku($facility, $skuData);
        }
"""
def sub(path, old, new):
    s=open(path).read(); assert s.count(old)==1, (path, old[:60]); open(path,'w').write(s.replace(old,new))
m=sys.argv[1]
if m=='M17':   # resend without an id (and without the bad-map guard): any failed update is resent once
    sub(SVC, LOOP, """        $results = [];
        foreach ($facilities as $facility) {
            $results[$facility] = $this->updateSku($facility, $skuData);
            if (($results[$facility]['status'] ?? null) === 'failure') { $this->updateSku($facility, $skuData); } // MUTANT M17
        }
""")
elif m=='M5':  # send the map id with no ambiguity guard
    sub(SVC, LOOP, """        $results = [];
        foreach ($facilities as $facility) {
            $data = $skuData; // MUTANT M5
            $mapId = \\App\\Models\\ProductWmsItem::where('product_id', $product->product_id)->where('facility_code', $facility)->value('wms_item_id');
            if ($mapId !== null) { $data['facility_item_id'] = (int) $mapId; }
            $results[$facility] = $this->updateSku($facility, $data);
        }
""")
elif m=='M2':  # send the map value even when NULL (drop the NULL omission)
    sub(SVC, LOOP, """        $results = [];
        foreach ($facilities as $facility) {
            $data = $skuData; // MUTANT M2
            $row = \\App\\Models\\ProductWmsItem::where('product_id', $product->product_id)->where('facility_code', $facility)->first();
            if ($row) { $data['facility_item_id'] = $row->wms_item_id; }
            $results[$facility] = $this->updateSku($facility, $data);
        }
""")
elif m=='M3':  # previous_sku sent unconditionally
    sub(SVC, LOOP, """        $results = [];
        if ($previousSku !== null) { $skuData['previous_sku'] = trim($previousSku); } // MUTANT M3
        foreach ($facilities as $facility) {
            $results[$facility] = $this->updateSku($facility, $skuData);
        }
""")
elif m=='M15': # C1 passes the previous SKU ignoring the client; service sends it when the SKU differs
    sub(SVC, LOOP, """        $results = [];
        if ($previousSku !== null && trim($previousSku) !== $skuData['sku']) { $skuData['previous_sku'] = trim($previousSku); } // MUTANT M15
        foreach ($facilities as $facility) {
            $results[$facility] = $this->updateSku($facility, $skuData);
        }
""")
    sub(PC, "            $wmsService->updateSkuFromProduct($product);\n",
        "            $wmsService->updateSkuFromProduct($product, $newlyResolvableAliases['previous_identity']['product_sku']); // MUTANT M15\n")
else: raise SystemExit('unknown mutant '+m)
print('applied', m)

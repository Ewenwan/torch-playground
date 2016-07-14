local datasets = require 'datasets/init'
local Threads = require 'threads'
Threads.serialization('threads.sharedserialize')

local M = {}
local DataLoader = torch.class('quantization.DataLoader', M)

function DataLoader.create(opt)
    local loaders = {}

    for i, split in ipairs{'train', 'val'} do
        local dataset = datasets.create(opt, split)
        loaders[i] = M.DataLoader(dataset, opt, split)
    end

    return table.unpack(loaders)
end

function DataLoader:__init(dataset, opt, split)
    local function init()
        require('datasets/' .. opt.dataset)
    end
    local function main(idx)
        _G.dataset = dataset
        _G.preprocess = dataset:preprocess()
        return dataset:size()
    end

    local threads, sizes = Threads(opt.nThreads, init, main)
    self.nCrops = (split == 'val' and opt.tenCrop) and 10 or 1
    self.threads = threads
    self.__size = sizes[1][1]
    self.batchSize = math.floor(opt.batchSize / self.nCrops)
end

function DataLoader:size()
    return math.ceil(self.__size / self.batchSize)
end

function DataLoader:run()
    local threads = self.threads
    local size, batchSize = self.__size, self.batchSize
    torch.manualSeed(11)
    local perm = torch.randperm(size)
    local idx, sample = 1, nil
    local function enqueue()
        while idx <= size and threads:acceptsjob() do
            local indices = perm:narrow(1, idx, math.min(batchSize, size - idx + 1))
            threads:addjob(
                function(indices, nCrops)
                    local sz = indices:size(1)
                    local batch, imageSize
                    local target = torch.IntTensor(sz)
                    for i, idx in ipairs(indices:totable()) do
                        local sample = _G.dataset:get(idx)
                        local input = _G.preprocess(sample.input)
                        if not batch then
                            imageSize = input:size():totable()
                            if nCrops > 1 then table.remove(imageSize, 1) end
                            batch = torch.FloatTensor(sz, nCrops, table.unpack(imageSize))
                        end
                        batch[i]:copy(input)
                        target[i] = sample.target
                    end
                    collectgarbage()
                    return {
                        input = batch:view(sz * nCrops, table.unpack(imageSize)):int(),
                        target = target,
                    }
                end,
                function(_sample_)
                    sample = _sample_
                end,
                indices,
                self.nCrops
            )
            idx = idx + batchSize
        end
    end

    local n = 0
    local function loop()
        enqueue()
        if not threads:hasjob() then
            return nil
        end
        threads:dojob()
        if threads:haserror() then
            threads:synchronize()
        end
        enqueue()
        n = n + 1
        return n, sample
    end
    return loop
end

function DataLoader:reset()
    self.threads:synchronize()
end

return M.DataLoader

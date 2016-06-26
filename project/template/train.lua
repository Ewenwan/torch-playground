local optim = require 'optim'

local M = {}
local Trainer = torch.class('template.Trainer', M)

function Trainer:getBestStat()
    keys = {'bestTop1', 'bestTop5'}
    vals = {math.huge, math.huge}
    return keys, vals
end

function Trainer:__init(model, criterion, optimState, opt)
    self.model = model
    self.criterion = criterion
    self.optimState = optimState or {
        learningRate = opt.LR,
        learningRateDecay = 0.0,
        momentum = opt.momentum,
        nesterov = true,
        dampening = 0.0,
        weightDecay = opt.weightDecay,
    }
    self.opt = opt
    self.params, self.gradParams = model:getParameters()
end

function Trainer:train(epoch, dataloader)
    local size = dataloader:size()
    self.optimState.learningRate = self:learningRate(epoch)
    
    local function feval()
        return self.criterion.output, self.gradParams
    end
    print('=> Training epoch # ' .. epoch .. ' LR: ' .. self.optimState.learningRate)
    local lossSum = 0.0
    local N = 0
    
    self.model:training()
    for n, sample in dataloader:run() do
        self:copyInputs(sample)
        self.model:forward(self.input)
        local loss = self.criterion:forward(self.model.output, self.target)
        self.model:zeroGradParameters()
        self.criterion:backward(self.model.output, self.target)
        self.model:backward(self.input, self.criterion.gradInput)
        optim.sgd(feval, self.params, self.optimState)
        print((' | Train [%d/%d] Loss: %3.3f'):format(n, size, loss))
        lossSum = lossSum + loss
    end
    print((' | Train Done, Loss: %3.3f'):format(lossSum / N))
    assert(self.params:storage() == self.model:parameters()[1]:storage())
end

function Trainer:val(dataloader)
    local size = dataloader:size()
    local nCrops = self.opt.tenCrop and 10 or 1
    local top1Sum, top5Sum = 0.0, 0.0
    local N = 0

    self.model:evaluate()
    for n, sample in dataloader:run() do
        self:copyInputs(sample)
        output = self.model:forward(self.input):float()
        loss = self.criterion:forward(self.model.output, self.target)

        local top1, top5 = self:computeScore(output, sample.target, nCrops)
        top1Sum = top1Sum + top1
        top5Sum = top5Sum + top5
        N = N + 1
        print((' | Val [%d/%d] Top1: %7.5f, Top5: %7.5f'):format(n, size, top1, top5))
    end

    print((' * Val Done, Top1: %7.3f  Top5: %7.3f'):format(top1Sum / N, top5Sum / N))
    vals = {top1Sum / N, top5Sum / N}
    return vals
end

function Trainer:computeScore(output, target, nCrops)
    if nCrops > 1 then
        -- Sum over crops
        output = output:view(output:size(1) / nCrops, nCrops, output:size(2))
        --:exp()
        :sum(2):squeeze(2)
    end

    -- Coputes the top1 and top5 error rate
    local batchSize = output:size(1)

    local _ , predictions = output:float():sort(2, true) -- descending

    -- Find which predictions match the target
    local correct = predictions:eq(
        target:long():view(batchSize, 1):expandAs(output))

    -- Top-1 score
    local top1 = 1.0 - (correct:narrow(2, 1, 1):sum() / batchSize)

    -- Top-5 score, if there are at least 5 classes
    local len = math.min(5, correct:size(2))
    local top5 = 1.0 - (correct:narrow(2, 1, len):sum() / batchSize)

    return top1 * 100, top5 * 100
end

function Trainer:copyInputs(sample)
    self.input = self.input or (self.opt.nGPU == 1
        and torch.CudaTensor()
        or cutorch.createCudaHostTensor())
    self.target = self.target or torch.CudaTensor()

    self.input:resize(sample.input:size()):copy(sample.input)
    self.target:resize(sample.target:size()):copy(sample.target)
end

function Trainer:learningRate(epoch)
    decay = epoch >= 375 and 4 or epoch >= 350 and 3 or epoch >= 300 and 2 or epoch >=200 and 1 or 0
    return self.opt.LR * math.pow(0.1, decay)
end

return M.Trainer
